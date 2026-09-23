/**
 * Windows toast notifications for opencode.
 *
 * opencode's built-in `attention` emits OSC 9 / OSC 777 terminal escapes,
 * which Windows Terminal does not render as notifications. This plugin sends a
 * real Windows toast via Windows PowerShell 5.1 + WinRT instead.
 *
 * Env overrides:
 *   OPENCODE_NOTIFY=0            disable entirely
 *   OPENCODE_NOTIFY_SCENARIO     default | urgent | alarm | reminder
 *   OPENCODE_NOTIFY_SOUND=0      no sound
 *   OPENCODE_NOTIFY_ON_IDLE=0    skip "session idle" (notify only on question/permission/error)
 *   OPENCODE_NOTIFY_APPID        AUMID to send as
 */

import { spawn } from "node:child_process";
import { appendFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin } from "@opencode-ai/plugin";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * Diagnostics: append every event to a file. opencode's own log does not record
 * event dispatch, so this is how you tell "hook never fired" from "fired but
 * the toast was suppressed". Disable with OPENCODE_NOTIFY_LOG=0.
 */
function traceEvent(line: string): void {
  if (process.env.OPENCODE_NOTIFY_LOG === "0") return;
  try {
    appendFileSync(join(HERE, "notify-windows.events.log"), `${new Date().toISOString()} ${line}\n`, "utf8");
  } catch {
    /* diagnostics must never break anything */
  }
}
// Installed layout: <plugins>/notify-windows.ts + <plugins>/notify/notify.ps1
// Repo layout:      <repo>/src/notify-windows.ts + <repo>/src/notify.ps1
const SCRIPT_CANDIDATES = [join(HERE, "notify", "notify.ps1"), join(HERE, "notify.ps1")];

// PowerShell 5.1 is required: PowerShell 7 does not expose the WinRT toast API.
const PS = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

const enabled = process.env.OPENCODE_NOTIFY !== "0";
const scenario = process.env.OPENCODE_NOTIFY_SCENARIO ?? "urgent";
const sound = process.env.OPENCODE_NOTIFY_SOUND !== "0";
const notifyOnIdle = process.env.OPENCODE_NOTIFY_ON_IDLE !== "0";
const debug = process.env.OPENCODE_NOTIFY_DEBUG === "1";

const SCRIPT = SCRIPT_CANDIDATES.find((p) => existsSync(p)) ?? SCRIPT_CANDIDATES[0]!;

/**
 * De-duplicate notifications of the same kind within a short window.
 *
 * A single "turn finished" can fire several idle signals (session.status idle
 * and session.idle, sometimes twice in the same second, and an ESC interrupt
 * produces a burst). Without this, one end-of-turn becomes four toasts.
 */
const DEDUP_MS = Number(process.env.OPENCODE_NOTIFY_DEDUP_MS ?? 3000);
const lastSent = new Map<string, number>();

function shouldSend(kind: string): boolean {
  const now = Date.now();
  const prev = lastSent.get(kind) ?? 0;
  if (now - prev < DEDUP_MS) {
    traceEvent(`toast: suppressed duplicate ${kind} (within ${DEDUP_MS}ms)`);
    return false;
  }
  lastSent.set(kind, now);
  return true;
}

/**
 * Send one toast, awaiting the PowerShell process.
 *
 * Two earlier approaches both failed inside opencode:
 *   - detached + stdio:"ignore" + unref(): the child was reaped before
 *     PowerShell ran (Windows), so the log said "sending" but nothing appeared.
 *   - Bun.spawnSync: intermittently returned exitCode=null within ~3ms, i.e.
 *     the spawn was aborted before starting. Blocking the event loop inside
 *     opencode's runtime is not reliable.
 *
 * This version spawns asynchronously (not detached, pipes drained) and awaits
 * exit. It is deterministic and does not block the event loop.
 */
function sendToast(title: string, message: string, overrideScenario?: string): Promise<void> {
  if (!enabled || process.platform !== "win32") return Promise.resolve();

  return new Promise<void>((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(PS, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT], {
        env: {
          ...process.env,
          NOTIFY_TITLE: title,
          NOTIFY_MSG: message.slice(0, 400),
          NOTIFY_SCENARIO: overrideScenario ?? scenario,
          NOTIFY_SOUND: sound ? "1" : "0",
        },
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (cause) {
      traceEvent(`toast: spawn threw ${cause instanceof Error ? cause.message : String(cause)}`);
      resolve();
      return;
    }

    let out = "";
    child.stdout?.on("data", (d) => (out += d.toString()));
    child.stderr?.on("data", (d) => (out += d.toString()));

    const timer = setTimeout(() => {
      child.kill();
      traceEvent("toast: timed out after 8s (killed)");
      resolve();
    }, 8000);

    child.on("error", (cause) => {
      clearTimeout(timer);
      traceEvent(`toast: error ${cause.message}`);
      resolve();
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const err = out.trim();
      traceEvent(`toast: exit=${code}${err ? ` out=${err.slice(0, 200)}` : ""}`);
      resolve();
    });
  });
}

export const NotifyWindowsPlugin: Plugin = async ({ client, directory }) => {
  if (!enabled || process.platform !== "win32") {
    return {};
  }
  if (!existsSync(SCRIPT)) {
    await client.app
      .log({
        body: {
          service: "notify-windows",
          level: "warn",
          message: `notify.ps1 not found (looked in: ${SCRIPT_CANDIDATES.join(", ")}); notifications disabled`,
        },
      })
      .catch(() => {});
    return {};
  }

  await client.app
    .log({
      body: {
        service: "notify-windows",
        level: "info",
        message: "Windows toast notifications enabled",
        extra: { scenario, sound, notifyOnIdle },
      },
    })
    .catch(() => {});

  /** A short label for the project, so notifications are distinguishable. */
  const projectLabel = (() => {
    const base = (directory || process.cwd()).replace(/\\/g, "/").split("/").filter(Boolean).pop();
    return base ?? "opencode";
  })();

  return {
    event: async ({ event }) => {
      const type = event.type;

      // Diagnostics: set OPENCODE_NOTIFY_DEBUG=1 to log every event, which is
      // how you tell "hook not called" from "wrong event name".
      if (debug) {
        await client.app
          .log({
            body: {
              service: "notify-windows",
              level: "info",
              message: `event: ${type}`,
              extra: { payload: JSON.stringify(event).slice(0, 300) },
            },
          })
          .catch(() => {});
      }

      traceEvent(`event:${type}`);

      // V2 signals "session is now idle" via session.status with status.type
      // === "idle". The standalone session.idle event is not emitted in
      // practice, which is why an idle-only hook never fired.
      if (type === "session.status") {
        const status = (event as { properties?: { status?: { type?: string } } }).properties?.status;
        if (status?.type === "idle") {
          if (!notifyOnIdle) return;
          if (!shouldSend("idle")) return;
          traceEvent("toast: status idle -> sending");
          await sendToast(`${projectLabel} · 完成`, "agent 已结束，可以查看了");
        }
        return;
      }

      if (type === "session.idle") {
        if (!notifyOnIdle) return;
        if (!shouldSend("idle")) return;
        traceEvent("toast: idle -> sending");
        await sendToast(`${projectLabel} · 完成`, "agent 已结束，可以查看了");
        return;
      }

      if (type === "permission.asked" || type === "permission.updated") {
        if (!shouldSend("permission")) return;
        traceEvent("toast: permission -> sending");
        await sendToast(`${projectLabel} · 需要授权`, "agent 正在等待你的权限确认", "urgent");
        return;
      }

      // The agent asked the user a question (the `question` tool). This is the
      // "needs a decision" case and must reach the user reliably.
      if (type === "question.asked") {
        if (!shouldSend("question")) return;
        traceEvent("toast: question -> sending");
        await sendToast(`${projectLabel} · 需要你回答`, "agent 提了一个问题，等待你的决定", "urgent");
        return;
      }

      if (type === "session.error") {
        if (!shouldSend("error")) return;
        traceEvent("toast: error -> sending");
        await sendToast(`${projectLabel} · 出错`, "会话发生错误，请检查", "urgent");
        return;
      }
    },
  };
};

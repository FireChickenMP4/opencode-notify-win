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
/** Click a toast to bring the originating window to the front (best-effort). */
const clickToActivate = process.env.OPENCODE_NOTIFY_CLICK_ACTIVATE === "1";
/** Flash the taskbar button so the window draws attention. On by default. */
const flashWindow = process.env.OPENCODE_NOTIFY_FLASH !== "0";

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
 * Toast sending is serialised through a queue.
 *
 * opencode does not await event handlers, so several `event` invocations can
 * run concurrently. Two PowerShell processes starting at once produced
 * intermittent `exit=null` (the spawn aborted within a few ms). Running one at
 * a time removes the race; a failed attempt is retried once.
 */
let queue: Promise<void> = Promise.resolve();

function sendToast(title: string, message: string, overrideScenario?: string): Promise<void> {
  const next = queue.then(() => attemptToast(title, message, overrideScenario));
  // Keep the chain alive even if a link rejects.
  queue = next.catch(() => {});
  return next;
}

async function attemptToast(title: string, message: string, overrideScenario?: string): Promise<void> {
  if (!enabled || process.platform !== "win32") return;
  for (let i = 1; i <= 2; i++) {
    const code = await runPowerShellToast(title, message, overrideScenario, i);
    if (code === 0) return;
    traceEvent(`toast: attempt ${i} failed (exit=${code})`);
  }
}

function runPowerShellToast(
  title: string,
  message: string,
  overrideScenario: string | undefined,
  attempt: number,
): Promise<number | null> {
  return new Promise<number | null>((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(PS, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT], {
        env: {
          ...process.env,
          NOTIFY_TITLE: title,
          NOTIFY_MSG: message.slice(0, 400),
          NOTIFY_SCENARIO: overrideScenario ?? scenario,
          NOTIFY_SOUND: sound ? "1" : "0",
          // Flash the taskbar button of the window hosting this session. Pure
          // Win32, works reliably from a script.
          ...(flashWindow ? { NOTIFY_FLASH_PID: String(process.pid) } : {}),
          // Click-to-activate is best-effort: the launch URI is set, but a
          // toast submitted by a plain PowerShell script does not receive the
          // click callback (that needs a COM INotificationActivationCallback).
          // Kept so it works wherever the platform does deliver the click.
          ...(clickToActivate ? { NOTIFY_ACTIVATE_PID: String(process.pid) } : {}),
        },
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (cause) {
      traceEvent(`toast: spawn threw ${cause instanceof Error ? cause.message : String(cause)}`);
      resolve(null);
      return;
    }

    let out = "";
    child.stdout?.on("data", (d) => (out += d.toString()));
    child.stderr?.on("data", (d) => (out += d.toString()));

    const timer = setTimeout(() => {
      child.kill();
      traceEvent("toast: timed out after 8s (killed)");
      resolve(null);
    }, 8000);

    child.on("error", (cause) => {
      clearTimeout(timer);
      traceEvent(`toast: error ${cause.message}`);
      resolve(null);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const extra = out.trim();
      traceEvent(`toast: exit=${code}${extra ? ` out=${extra.slice(0, 200)}` : ""}${attempt > 1 ? " (retry)" : ""}`);
      resolve(code);
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

  /**
   * Identify the session's workspace unambiguously.
   *
   * Only the basename was shown before, so two opencode sessions in different
   * projects with the same folder name (or the same project opened twice) were
   * indistinguishable in a notification. The full path (with a ~ shorthand for
   * the home dir) tells you which one fired.
   */
  const workspace = (() => {
    const dir = directory || process.cwd();
    const home = process.env.USERPROFILE || process.env.HOME || "";
    const short = home && dir.toLowerCase().startsWith(home.toLowerCase()) ? `~${dir.slice(home.length)}` : dir;
    return short.replace(/\\/g, "/");
  })();

  /** Last path segment, used where a short label reads better. */
  const workspaceName = workspace.split("/").filter(Boolean).pop() ?? "opencode";

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
          await sendToast(`opencode · 完成 [${workspace}]`, "agent 已结束，可以查看了");
        }
        return;
      }

      if (type === "session.idle") {
        if (!notifyOnIdle) return;
        if (!shouldSend("idle")) return;
        traceEvent("toast: idle -> sending");
        await sendToast(`opencode · 完成 [${workspace}]`, "agent 已结束，可以查看了");
        return;
      }

      if (type === "permission.asked" || type === "permission.updated") {
        if (!shouldSend("permission")) return;
        traceEvent("toast: permission -> sending");
        await sendToast(`opencode · 需要授权 [${workspace}]`, "agent 正在等待你的权限确认", "urgent");
        return;
      }

      // The agent asked the user a question (the `question` tool). This is the
      // "needs a decision" case and must reach the user reliably.
      if (type === "question.asked") {
        if (!shouldSend("question")) return;
        traceEvent("toast: question -> sending");
        await sendToast(`opencode · 需要你回答 [${workspace}]`, "agent 提了一个问题，等待你的决定", "urgent");
        return;
      }

      if (type === "session.error") {
        // An ESC interrupt arrives as session.error with name
        // "MessageAbortedError". That is a deliberate user action, not a
        // failure, so it must not raise an "error" notification.
        const errName = (event as { properties?: { error?: { name?: string } } }).properties?.error?.name;
        if (errName === "MessageAbortedError") {
          traceEvent("toast: skipped (user aborted)");
          return;
        }
        if (!shouldSend("error")) return;
        traceEvent(`toast: error -> sending (${errName ?? "unknown"})`);
        await sendToast(`opencode · 出错 [${workspace}]`, "会话发生错误，请检查", "urgent");
        return;
      }
    },
  };
};

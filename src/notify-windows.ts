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
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin } from "@opencode-ai/plugin";

const HERE = dirname(fileURLToPath(import.meta.url));
// Installed layout: <plugins>/notify-windows.ts + <plugins>/notify/notify.ps1
// Repo layout:      <repo>/src/notify-windows.ts + <repo>/src/notify.ps1
const SCRIPT_CANDIDATES = [join(HERE, "notify", "notify.ps1"), join(HERE, "notify.ps1")];

// PowerShell 5.1 is required: PowerShell 7 does not expose the WinRT toast API.
const PS = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

const enabled = process.env.OPENCODE_NOTIFY !== "0";
const scenario = process.env.OPENCODE_NOTIFY_SCENARIO ?? "urgent";
const sound = process.env.OPENCODE_NOTIFY_SOUND !== "0";
const notifyOnIdle = process.env.OPENCODE_NOTIFY_ON_IDLE !== "0";

const SCRIPT = SCRIPT_CANDIDATES.find((p) => existsSync(p)) ?? SCRIPT_CANDIDATES[0]!;

/** Send one toast. Fire-and-forget; a failure must never break a session. */
function toast(title: string, message: string, overrideScenario?: string): void {
  if (!enabled || process.platform !== "win32") return;
  try {
    const child = spawn(PS, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT], {
      env: {
        ...process.env,
        NOTIFY_TITLE: title,
        NOTIFY_MSG: message.slice(0, 400),
        NOTIFY_SCENARIO: overrideScenario ?? scenario,
        NOTIFY_SOUND: sound ? "1" : "0",
      },
      stdio: "ignore",
      windowsHide: true,
      detached: true,
    });
    child.on("error", () => {});
    child.unref();
  } catch {
    /* never throw from a notification path */
  }
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

      if (type === "session.idle") {
        if (!notifyOnIdle) return;
        toast(`${projectLabel} · 完成`, "agent 已结束，可以查看了");
        return;
      }

      if (type === "permission.asked") {
        toast(`${projectLabel} · 需要授权`, "agent 正在等待你的权限确认", "urgent");
        return;
      }

      if (type === "session.error") {
        toast(`${projectLabel} · 出错`, "会话发生错误，请检查", "urgent");
        return;
      }
    },
  };
};

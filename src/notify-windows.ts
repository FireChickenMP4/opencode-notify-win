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
 *   OPENCODE_NOTIFY_SUBAGENT=1   also notify when a subagent finishes (default off)
 *   OPENCODE_NOTIFY_LOG=0        disable the diagnostics event log
 *   OPENCODE_NOTIFY_LOG_MAX      rotate the diagnostics log past this many bytes
 *   OPENCODE_NOTIFY_APPID        AUMID to send as
 *   OPENCODE_NOTIFY_DEDUP_MS     suppress a repeated notification of the same kind (default 3000)
 *   OPENCODE_NOTIFY_PERMISSION_GRACE_MS
 *                                auto-accept mode only: how long to wait before deciding a
 *                                permission request really is waiting (default 1500). With
 *                                manual approval the toast goes out at once.
 */

import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin } from "@opencode/plugin";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * Cap for the diagnostics log. It is rotated to `.1` (one previous generation)
 * once it grows past this, so a long-lived session cannot fill the disk.
 */
const LOG_MAX_BYTES = Number(process.env.OPENCODE_NOTIFY_LOG_MAX ?? 5 * 1024 * 1024);

/** Amortise the size check: a syscall per streamed delta would be wasteful. */
let logWrites = 0;

/**
 * Diagnostics: record the events this plugin acts on, plus internal
 * skip/send decisions. opencode's own log does not record event dispatch, so
 * this is how you tell "hook never fired" from "fired but the toast was
 * suppressed". High-frequency streaming events are excluded on purpose - the
 * full event dump is available with OPENCODE_NOTIFY_DEBUG=1. Disable with
 * OPENCODE_NOTIFY_LOG=0.
 */
function traceEvent(line: string): void {
  if (process.env.OPENCODE_NOTIFY_LOG === "0") return;
  const path = join(HERE, "notify-windows.events.log");
  try {
    if (++logWrites % 256 === 0 && statSync(path).size > LOG_MAX_BYTES) {
      // Bun on Windows replaces an existing target, so no pre-delete needed.
      renameSync(path, `${path}.1`);
    }
  } catch {
    /* size check is best-effort; never break the event path */
  }
  try {
    appendFileSync(path, `${new Date().toISOString()} ${line}\n`, "utf8");
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

/** Event types the plugin acts on; only these go into the diagnostics log. */
const TRACED_EVENTS = new Set([
  "session.status",
  "session.idle",
  "permission.asked",
  "form.created",
  "session.execution.failed",
]);

/**
 * Shape of the events this plugin reads. V2 carries every payload under `data`
 * (V1 used `properties`), and only the fields actually used are declared here.
 */
type NotifyEvent = {
  type: string;
  /** The location the event was published for; the session's own directory. */
  location?: { directory?: string };
  data?: {
    id?: string;
    sessionID?: string;
    status?: { type?: string };
    error?: { type?: string; message?: string };
  };
};

/**
 * Path of the CLI settings file, where automatic approval of permission
 * requests is configured.
 */
function cliConfigPath(): string {
  const base = process.env.XDG_CONFIG_HOME || join(homedir(), ".config");
  return join(base, "opencode", "cli.json");
}

/**
 * True when the CLI answers permission requests on its own.
 *
 * Only then can a request be resolved before a human ever sees it, which is the
 * one case where "需要授权" would be noise. Read fresh, so flipping the setting
 * takes effect without a restart.
 */
function autoAcceptEnabled(): boolean {
  try {
    const cfg = JSON.parse(readFileSync(cliConfigPath(), "utf8")) as { session?: { permissions?: unknown } };
    const mode = cfg.session?.permissions;
    return typeof mode === "string" && mode.toLowerCase().replace(/[-_]/g, "") === "autoaccept";
  } catch {
    // Unreadable settings: assume requests are answered by hand, so notify at once.
    return false;
  }
}

/**
 * De-duplicate notifications of the same kind within a short window.
 *
 * A single "turn finished" can fire several idle signals (session.status idle
 * and session.idle, sometimes twice in the same second, and an ESC interrupt
 * produces a burst). Without this, one end-of-turn becomes four toasts.
 *
 * The window is claimed through the filesystem rather than an in-memory map:
 * opencode loads a local plugin more than once, and the instances do not share
 * module state, so a counter would let each one toast the same event.
 */
const DEDUP_MS = Number(process.env.OPENCODE_NOTIFY_DEDUP_MS ?? 3000);
const DEDUP_DIR = join(tmpdir(), "opencode-notify", "notify-windows");

/** Only notify about a permission that is still unanswered after this long. */
const PERMISSION_GRACE_MS = Number(process.env.OPENCODE_NOTIFY_PERMISSION_GRACE_MS ?? 1500);

function shouldSend(kind: string): boolean {
  const claim = join(DEDUP_DIR, kind);
  try {
    mkdirSync(DEDUP_DIR, { recursive: true });
    // An exclusive create succeeds for exactly one instance per window.
    mkdirSync(claim);
    return true;
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException)?.code !== "EEXIST") {
      // Cannot claim at all: fail open, a notification matters more than noise.
      return true;
    }
    try {
      // A winner that never came back (crash) must not block the kind forever.
      if (Date.now() - statSync(claim).mtimeMs >= DEDUP_MS) {
        rmSync(claim, { recursive: true, force: true });
        return shouldSend(kind);
      }
    } catch {
      /* the claim vanished between the two calls */
    }
    traceEvent(`toast: suppressed duplicate ${kind} (within ${DEDUP_MS}ms)`);
    return false;
  }
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

/** V2 plugin entrypoint. Returns a cleanup that stops the event subscription. */
async function setup(ctx: Plugin.Context): Promise<(() => void) | undefined> {
  if (!enabled || process.platform !== "win32") {
    return;
  }
  if (!existsSync(SCRIPT)) {
    console.error(
      `[notify-windows] notify.ps1 not found (looked in: ${SCRIPT_CANDIDATES.join(", ")}); notifications disabled`,
    );
    return;
  }

  console.log(
    `[notify-windows] Windows toast notifications enabled (scenario=${scenario}, sound=${sound}, onIdle=${notifyOnIdle})`,
  );

  /**
   * Identify the session's workspace unambiguously.
   *
   * Only the basename was shown before, so two opencode sessions in different
   * projects with the same folder name (or the same project opened twice) were
   * indistinguishable in a notification. The full path (with a ~ shorthand for
   * the home dir) tells you which one fired.
   *
   * The directory comes from the event (or the session), never from this plugin
   * instance: opencode loads a local plugin once per location, so the instance's
   * own directory belongs to whichever location loaded it, not to the session
   * that fired the event.
   */
  function workspaceOf(event: NotifyEvent, fallback?: string): string {
    const dir = event.location?.directory ?? fallback ?? ctx.location.directory ?? process.cwd();
    const home = process.env.USERPROFILE || process.env.HOME || "";
    const short = home && dir.toLowerCase().startsWith(home.toLowerCase()) ? `~${dir.slice(home.length)}` : dir;
    return short.replace(/\\/g, "/");
  }

  /** Subagent activity is frequent; only notify about it on request. */
  const notifySubagent = process.env.OPENCODE_NOTIFY_SUBAGENT === "1";

  type SessionInfo = { parentID?: string; title?: string; directory?: string };
  const sessionCache = new Map<string, SessionInfo>();

  /**
   * Resolve whether a session is a subagent, and its title.
   *
   * `session.status` carries a sessionID but not the session record. We look it
   * up via the SDK so a subagent's finish is not reported as if the main turn
   * ended (the main session is still running while a subagent works).
   */
  async function sessionInfo(sessionID: string): Promise<SessionInfo> {
    const cached = sessionCache.get(sessionID);
    if (cached) return cached;
    try {
      // V2 returns the session record directly, not a `{ data }` envelope.
      const data = await ctx.session.get({ sessionID });
      const info: SessionInfo = { parentID: data.parentID, title: data.title, directory: data.location?.directory };
      sessionCache.set(sessionID, info);
      return info;
    } catch {
      // Fail open: unknown session is treated as a main session.
      return {};
    }
  }

  /** Drop the "(@general subagent)" tail and cap the length for a toast. */
  function shortTitle(title: string | undefined): string {
    if (!title) return "子代理";
    return title.replace(/\s*\(@\w+\s+subagent\)\s*$/i, "").trim().slice(0, 60) || "子代理";
  }

  /** A finished turn is reported once; a subagent's finish is not the main turn ending. */
  async function notifyIdle(event: NotifyEvent, sessionID: string | undefined): Promise<void> {
    if (!notifyOnIdle) return;

    const info = sessionID ? await sessionInfo(sessionID) : {};
    if (info.parentID) {
      // A subagent finished; the main session is still working.
      if (!notifySubagent) {
        traceEvent(`idle skipped: subagent (${shortTitle(info.title)})`);
        return;
      }
      if (!shouldSend("subagent")) return;
      traceEvent("toast: subagent idle -> sending");
      await sendToast(`opencode · 子代理完成 [${shortTitle(info.title)}]`, "子代理已返回");
      return;
    }

    if (!shouldSend("idle")) return;
    traceEvent("toast: idle -> sending");
    await sendToast(`opencode · 完成 [${workspaceOf(event, info.directory)}]`, "agent 已结束，可以查看了");
  }

  /**
   * True when a permission request is still unanswered after a short grace.
   *
   * Only auto-accept can resolve a request before a human sees it, so with
   * manual approval there is nothing to wait for and the toast goes out at
   * once. Fails open: a lookup error counts as "still waiting", so a real
   * notice is never lost.
   */
  async function stillWaiting(data: NotifyEvent["data"]): Promise<boolean> {
    const sessionID = data?.sessionID;
    const requestID = data?.id;
    if (!sessionID || !requestID) return true;
    if (!autoAcceptEnabled()) return true;
    await new Promise((r) => setTimeout(r, PERMISSION_GRACE_MS));
    try {
      const pending = await ctx.permission.list({ sessionID });
      return pending.some((p) => p.id === requestID);
    } catch {
      return true;
    }
  }

  /** Handle one V2 event; V2 carries every payload under `data`. */
  async function handleEvent(event: NotifyEvent): Promise<void> {
    const type = event.type;

    // Diagnostics: set OPENCODE_NOTIFY_DEBUG=1 to log every event, which is
    // how you tell "hook not called" from "wrong event name".
    if (debug) {
      console.log(`[notify-windows] event: ${type} ${JSON.stringify(event).slice(0, 300)}`);
    }

    // Only trace events this plugin acts on. Streaming deltas
    // (session.text.delta) fire per token and once accounted for a 40MB log;
    // the full event dump is available behind OPENCODE_NOTIFY_DEBUG=1.
    if (TRACED_EVENTS.has(type)) traceEvent(`event:${type}`);

    // Both session.status/idle and the standalone session.idle carry the
    // sessionID; whichever fires, the subagent check must run so a subagent
    // finishing is not reported as the main turn ending.
    if (type === "session.status") {
      if (event.data?.status?.type !== "idle") return;
      await notifyIdle(event, event.data?.sessionID);
      return;
    }

    if (type === "session.idle") {
      await notifyIdle(event, event.data?.sessionID);
      return;
    }

    if (type === "permission.asked") {
      // An auto-accepted request is answered within milliseconds; only a
      // request that is genuinely waiting for you deserves a toast.
      if (!(await stillWaiting(event.data))) {
        traceEvent("permission skipped: already resolved");
        return;
      }
      if (!shouldSend("permission")) return;
      traceEvent("toast: permission -> sending");
      await sendToast(`opencode · 需要授权 [${workspaceOf(event)}]`, "agent 正在等待你的权限确认", "urgent");
      return;
    }

    // The agent asked the user a question (the `question` tool). V2 surfaces it
    // as `form.created`; it is the "needs a decision" case and must reach the
    // user reliably.
    if (type === "form.created") {
      if (!shouldSend("question")) return;
      traceEvent("toast: question -> sending");
      await sendToast(`opencode · 需要你回答 [${workspaceOf(event)}]`, "agent 提了一个问题，等待你的决定", "urgent");
      return;
    }

    // A failed turn. An ESC interrupt is not a failure: V2 reports a deliberate
    // interrupt as session.execution.interrupted (ignored here), and any abort
    // that still surfaces as an error carries MessageAbortedError.
    if (type === "session.execution.failed") {
      if (event.data?.error?.type === "MessageAbortedError") {
        traceEvent("toast: skipped (user aborted)");
        return;
      }
      if (!shouldSend("error")) return;
      traceEvent(`toast: error -> sending (${event.data?.error?.type ?? "unknown"})`);
      await sendToast(`opencode · 出错 [${workspaceOf(event)}]`, "会话发生错误，请检查", "urgent");
      return;
    }
  }

  const controller = new AbortController();
  void (async () => {
    for await (const raw of ctx.event.subscribe({ signal: controller.signal })) {
      try {
        await handleEvent(raw as unknown as NotifyEvent);
      } catch (cause) {
        // One bad event must never kill the subscription.
        traceEvent(`handler error: ${cause instanceof Error ? cause.message : cause}`);
      }
    }
  })();

  return () => controller.abort();
}

export default { id: "notify-windows", setup };

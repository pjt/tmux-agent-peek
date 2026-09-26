/**
 * pi-title-state — publish pi's agent state in the terminal title.
 *
 * Optional companion to tmux-agent-peek. Rewrites pi's title from
 *   "π - <session name - ><cwd>"   to   "π <glyph> <session name - ><cwd>"
 * where glyph is one of ▲ ✖ ■ ✻ ✔ ○. The title travels as an OSC 2 escape
 * through ssh, zmx, docker, mosh, nested tmux… and lands in the local tmux
 * pane's #{pane_title}, where tmux-agent-peek reads it. That gives exact state
 * for remote/containerised agents without hooks or network calls.
 *
 * pi still rewrites the plain title on some events (session switch, rename,
 * /reload). Until the next state change, tmux-agent-peek just falls back to
 * reading the screen — nothing breaks.
 *
 * Install: copy or symlink into ~/.pi/agent/extensions/ on whichever machine
 * (or container) runs pi.
 *
 * Deliberately dependency-free (no pi type imports) so it loads anywhere.
 */

import { basename } from "node:path";

type State = "idle" | "working" | "completed" | "failed" | "stopped";

const GLYPH: Record<State, string> = {
  idle: "○",
  working: "✻",
  completed: "✔",
  failed: "✖",
  stopped: "■",
};

export default function piTitleState(pi: any): void {
  let state: State = "idle";
  let settled: State = "completed";

  function render(ctx: any): void {
    if (ctx?.mode !== "tui" || !ctx.ui?.setTitle) return;
    const cwd = basename(ctx.cwd || process.cwd());
    const name = typeof pi.getSessionName === "function" ? pi.getSessionName() : undefined;
    ctx.ui.setTitle(`π ${GLYPH[state]} ${name ? `${name} - ` : ""}${cwd}`);
  }

  function set(next: State, ctx: any): void {
    state = next;
    render(ctx);
  }

  pi.on("session_start", (_event: any, ctx: any) => {
    // pi sets its own title right after binding extensions; go after it.
    setTimeout(() => set("idle", ctx), 100);
  });

  pi.on("agent_start", (_event: any, ctx: any) => {
    settled = "completed";
    set("working", ctx);
  });

  pi.on("agent_end", (event: { messages?: Array<{ role?: string; stopReason?: string }> }) => {
    const last = [...(event.messages || [])].reverse().find((m) => m.role === "assistant");
    if (last?.stopReason === "error") settled = "failed";
    else if (last?.stopReason === "aborted") settled = "stopped";
  });

  // agent_end can be followed by retries / compaction / queued follow-ups;
  // agent_settled is the real end of the turn.
  pi.on("agent_settled", (_event: any, ctx: any) => {
    set(settled, ctx);
  });

  pi.on("session_shutdown", (_event: any, ctx: any) => {
    // Leave no stale glyph behind for the shell that inherits the terminal.
    if (ctx?.mode === "tui" && ctx.ui?.setTitle) ctx.ui.setTitle("");
  });
}

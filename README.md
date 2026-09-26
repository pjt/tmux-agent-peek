# tmux-agent-peek

See every AI coding agent across your tmux sessions — **including ones running
over ssh, inside zmx/dtach, in Docker, or behind a nested tmux** — and jump to
any of them in one keystroke.

A fork of [tmux-agent-view](https://github.com/luopeixiang/tmux-agent-view)
that trades hooks for heuristics: discovery and state come **only from what
the local tmux server can already see** — pane titles, the pane's foreground
command, and the visible screen. No hooks, no `ps`, no daemon, no remote calls.

```
┌──────────────────────────────── ◉ agents ────────────────────────────────┐
│  enter jump · ctrl-r refresh · esc close                                  │
│▌  ▲ needs input  proj-a:1  claude  claude  fix login bug  ⎇ fix/login     │
│   ✻ working      local:5   node    pi      me       ~               │
│   ✔ completed    local:3   dht     pi      tmp            ~/tmp           │
│   ✔ completed    local:4   ssh     pi      dev            ⇄ via ssh       │
├───────────────────────────────────────────────────────────────────────────┤
│ (live preview of the selected agent's screen)                             │
└───────────────────────────────────────────────────────────────────────────┘
```

## Why

Hook-based tools write state from inside the agent process to a file on
*that* machine, keyed by `$TMUX_PANE`. When the agent runs on a remote host,
in a container, or under a session manager like zmx, there is no local
`$TMUX_PANE` and no local file — the agent is invisible.

But the agent's **terminal output** still flows into a local tmux pane:
its title (OSC 2) lands in `#{pane_title}`, its UI in the pane's screen. So
peek reads those.

## How it works

1. **Discover** — one `tmux list-panes -a` call. A pane is an agent pane if
   - its foreground command is an agent (`claude`, `codex`, `opencode`,
     `aider`, `goose`, `gemini`, `kimi`, `pi`), or
   - its title looks like an agent's (`π - …` for pi, `✳ …` for Claude Code —
     which keeps the `✳` while working, so its title never carries state) —
     unless the foreground is a local shell, which means the agent exited and
     left a stale title behind.

   If the foreground is `ssh`, `mosh`, `docker`, `zmx`, … the pane is marked
   as reached *via* that command.
2. **Read state**, first match wins:
   1. **Title glyph** — `π ✻ dev`: an exact state published by the agent
      itself. See [pi-title-state](#optional-exact-state-for-pi).
   2. **Screen** — one batched `tmux capture-pane` for every candidate
      (~10 ms total), classified by [`scripts/classify.awk`](scripts/classify.awk).
      The marker closest to the bottom of the screen wins.
3. **Infer** — a small per-server cache remembers each pane's last state.
   `working → idle` on screen becomes **completed** (stock pi leaves no
   "done" marker). Completed ages to idle after 30 min.
4. **Stale remote titles** — for panes reached via ssh/etc., if the screen
   shows no sign of the agent's UI (pi's token footer, Claude's prompt
   chrome) the pane is dropped: the agent exited and the remote shell kept
   its title.

Preview and jump are plain `tmux capture-pane` / `switch-client` — they work
for remote agents too, because the remote agent *is* drawing in a local pane.

## Agent states

| state | screen heuristic |
|---|---|
| `▲ needs input` | `Do you want …`, a numbered `❯ 1.` choice, Approve/Reject |
| `✖ failed` | `API Error`, rate limit / timeout / auth messages; pi `Error: …` |
| `■ stopped` | `⎿ Interrupted`; pi `Operation aborted` |
| `✻ working` | spinner line `✻ Doing… (…)`, `esc to interrupt`, pi `Working (esc to interrupt)` |
| `✔ completed` | `✻ Worked for 1m 5s`, `✻ Turn took 52s`, `※ recap:`; or inferred from working → idle |
| `○ idle` | none of the above |

## Optional: exact state for pi

[`extras/pi-title-state.ts`](extras/pi-title-state.ts) is a tiny pi extension
that rewrites pi's title from `π - dev` to `π <glyph> dev`, glyph ∈
`▲ ✖ ■ ✻ ✔ ○`. The title travels through ssh/zmx/docker like any other
output, so peek gets exact, event-driven state — including short turns that
finish between polls. Install it wherever pi runs (remote host, container):

```sh
cp extras/pi-title-state.ts ~/.pi/agent/extensions/
```

Any agent can join in by setting its title to `<mark> <glyph> <text>`.

## Notifications

The status-line segment is also the poller: each refresh
(`status-interval`, default 15 s) runs a scan, and state changes into
needs input / completed / failed / stopped raise a macOS banner — clickable
(jumps to the pane) with [terminal-notifier](https://github.com/julienXX/terminal-notifier),
plain via `osascript` otherwise. Banners are skipped when you're already
looking at the pane. Lower `status-interval` for snappier banners; a scan
costs ~30–150 ms.

## Install

Requires tmux ≥ 3.2 and [fzf](https://github.com/junegunn/fzf).

```tmux
run-shell ~/dev/tmux-agent-peek/agent-peek.tmux
```

Then `tmux source ~/.tmux.conf` and press `prefix + a`. If you also load
tmux-agent-view, set a different key for one of them.

## Options

| option | default | description |
|---|---|---|
| `@agent-peek-key` | `a` | key after prefix that opens the picker |
| `@agent-peek-status` | `on` | prepend the agent summary to `status-right` |
| `@agent-peek-notify` | `on` | macOS banners on state changes |
| `@agent-peek-completed-ttl` | `1800` | seconds before completed ages to idle (0 = never) |
| `@agent-peek-tail` | `40` | bottom screen lines the classifier examines |
| `@agent-peek-cmd-pattern` | see script | regex: foreground commands that are agents |
| `@agent-peek-title-pattern` | see script | regex: titles that identify an agent |
| `@agent-peek-via-pattern` | see script | regex: foreground commands meaning "remote" |
| `@agent-peek-width` / `-height` | `90%` / `75%` | popup size |

## Tuning the heuristics

```sh
scripts/agent-peek.sh debug        # every candidate: state, source, matched line
scripts/agent-peek.sh debug %27    # one pane
scripts/agent-peek.sh raw          # the exact classifier input
tests/run.sh                       # fixture tests
```

When peek gets a pane wrong, save the screen as a fixture named
`tests/fixtures/<expected-state>--<description>.txt` (header line
`::peek:: %1 <kind> <via>` + the capture), fix `classify.awk`, rerun tests.

## Limitations

- **Polling, not events.** Without the title extension, a turn that starts
  and finishes between two scans is never seen as working, so it's never
  inferred as completed.
- **Screen heuristics drift** as agent UIs and your own extensions change.
- **Only what's on a local screen.** A detached zmx/dtach session or a
  non-active pane of a remote tmux isn't visible.
- **Transcript text can fool it.** An agent quoting `Do you want to proceed?`
  near the bottom of the screen reads as needs input.

## License

MIT. Derived from tmux-agent-view © luopeixiang (MIT).

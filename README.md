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
     which keeps the `✳` while working, so its title never carries state).

   If the foreground is `ssh`, `mosh`, `docker`, `zmx`, … the pane is marked
   as reached *via* that command. If it's a shell, the pane is marked
   *via script*: a wrapper (say, a reconnect loop around `ssh`) leads the
   foreground process group, so tmux reports the script's interpreter.
2. **Read state from the screen** — one batched `tmux capture-pane` for
   every candidate (~10 ms total), classified by
   [`scripts/classify.awk`](scripts/classify.awk). The marker closest to the
   bottom of the screen wins. The title says *where* an agent is; the screen
   says *what* it's doing. Each covers the other's blind spot: stale titles
   are caught on screen, and agent-looking text in a non-agent pane (vim on
   a transcript) never gets past the title gate.
3. **Infer** — a small per-server cache remembers each pane's last state.
   Leaving *working* must **settle**: the spinner has to be absent from every
   scan for 10 s (`@agent-peek-settle`) — remote panes redraw in pieces, and
   a capture that lands mid-redraw sees no spinner. After that,
   `working → idle` becomes **completed** (stock pi leaves no "done" marker).
   Completed ages to idle after 30 min.
4. **Progress** — the same `list-panes` call reads `#{pane_pb_state}`, the
   OSC 9;4 progress state tmux (3.6+) keeps per pane. pi sets it for the
   whole run when `terminal.showTerminalProgress` is on, and it passes
   through ssh and zmx. When it turns on, the pane is working even if the
   capture missed the spinner; when it turns off, working ends at once, with
   no settle. While it stays on, a spinner-less screen holds working for up
   to 120 s (`@agent-peek-progress-hold`). That limit matters because the
   state can go stale: if the clear is lost (ssh dropped, agent crashed),
   tmux keeps the old value. (pi's newer OSC 7501 status report would say
   more, but tmux drops it.)
5. **Stale titles** — agents don't reset the title on exit, and pi leaves
   its last frame (footer included) on screen. So for panes found by title
   (via ssh/script/…), the pane is dropped if the agent's UI isn't visible
   (pi's token footer, Claude's prompt chrome) **or** the bottom line is a
   shell prompt (`❯`, `$`, `#`, `%`, `➜`, `λ`, `»`).

For agents behind ssh/zmx/a script, the local pane's cwd is meaningless,
so the place column shows what the agent itself displays: pi's footer line
`~/dev/web-api (spike/x) • session` becomes `⇄ ⎇ spike/x · ~/dev/web-api`.

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

## Notifications

The status-line segment is also the poller: each refresh
(`status-interval`, default 15 s) runs a scan, and turn boundaries — into
needs input from anything, into completed / failed / stopped from working —
raise an alert. Nothing fires when you're already looking at the pane.
Lower `status-interval` for snappier alerts; a scan costs ~30–150 ms.

Pick any combination with `@agent-peek-notify-style` (comma list):

| style | what happens |
|---|---|
| `banner` | macOS Notification Center, silent. Clickable (jumps to the pane) with [terminal-notifier](https://github.com/julienXX/terminal-notifier), plain via `osascript` otherwise |
| `sound` | plays `@agent-peek-sound-<state>`, else `@agent-peek-sound` (`afplay` / `paplay` / `aplay`) |
| `bell` | rings the terminal bell on every attached client (your terminal decides audible vs. visual) |
| `message` | `tmux display-message` on every attached client |

A sound is a file path (mp3/aiff/wav/caf, `~` ok) or a macOS system sound
name (`Glass`, `Ping`, `Funk`, `Hero`, … from `/System/Library/Sounds`).

```tmux
set -g @agent-peek-notify-style 'sound'                 # audio only
set -g @agent-peek-sound 'Glass'                        # default for all states
set -g @agent-peek-sound-needs_input 'Funk'             # per-state override
set -g @agent-peek-notify-states 'needs_input,completed' # skip failed/stopped
```

Try the current settings with `scripts/agent-peek.sh test-notify completed`.

Scans are serialized with a lock: tmux runs one status job per attached
client, and without it every client would detect — and announce — the same
transition.

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
| `@agent-peek-notify` | `on` | alerts on turn boundaries (`off` mutes all) |
| `@agent-peek-notify-style` | `banner` | comma list: `banner`, `sound`, `bell`, `message` |
| `@agent-peek-notify-states` | `needs_input,completed,failed,stopped` | which states alert |
| `@agent-peek-sound` | `Glass` | sound file or system sound name |
| `@agent-peek-sound-<state>` | — | per-state sound override |
| `@agent-peek-settle` | `10` | seconds the spinner must stay gone before leaving working |
| `@agent-peek-progress-hold` | `120` | seconds a pane's OSC 9;4 progress state can hold working with no spinner on screen |
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
scripts/agent-peek.sh log          # recent state transitions (with matched line)
tests/run.sh                       # fixture tests
```

When peek gets a pane wrong, save the screen as a fixture named
`tests/fixtures/<expected-state>--<description>.txt` (header line
`::peek:: %1 <kind> <via>` + the capture), fix `classify.awk`, rerun tests.

## Limitations

- **Polling, not events.** A turn that starts and finishes between two
  scans is never seen as working; it only reads as completed if the agent
  prints an end-of-turn marker (Claude's `✻ Worked for …`, `✻ Turn took …`).
- **Screen heuristics drift** as agent UIs and your own extensions change.
- **Only what's on a local screen.** A detached zmx/dtach session or a
  non-active pane of a remote tmux isn't visible.
- **Unusual prompts.** A shell prompt that doesn't end in one of the
  prompt characters above makes an exited agent's stale title look live.
- **Transcript text can fool it.** An agent quoting `Do you want to proceed?`
  near the bottom of the screen reads as needs input.

## License

MIT. Derived from tmux-agent-view © luopeixiang (MIT).

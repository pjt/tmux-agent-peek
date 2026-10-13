# Repository Guidelines

Small Bash tmux plugin, no build step.

- `agent-peek.tmux` — entry point: key binding + status-right segment.
- `scripts/agent-peek.sh` — discovery (`tmux list-panes`), batched capture,
  state merge/inference, notifications, fzf picker, jump.
- `scripts/classify.awk` — screen → state heuristics. Pure function of its
  input; all screen-pattern changes go here.
- `tests/run.sh` + `tests/fixtures/` — classifier fixtures, named
  `<expected-state>--<description>.txt`.

## Invariants

- Title = WHERE (discovery), screen = WHAT (state, liveness, remote place).
  Don't make the title carry state. The one exception: `#{pane_pb_state}`
  (OSC 9;4 progress, set by pi during a run) can say *working*. Trust its
  edges; never trust its level without a bound, because a lost clear leaves
  it on.
- Discovery and state use **only the local tmux server**: no `ps`, no hooks,
  no network. (`ps` is used solely to find the terminal app for notifications.)
- One `list-panes` and one batched `capture-pane` per scan.
- macOS Bash 3.2 and macOS awk (byte-oriented, 2020): no associative arrays
  in bash; multibyte glyphs only as literal alternations, never in `[…]`.
- Scan rows are tab-separated with no empty fields (`-` placeholder) because
  `read` collapses runs of tabs.
- `display-message` formats go through strftime: escape `%` as `%%`.

## Checks

```sh
bash -n agent-peek.tmux scripts/*.sh
tests/run.sh
scripts/agent-peek.sh debug
scripts/agent-peek.sh status
```

Commits: Conventional Commits (`feat:`, `fix:`, `refactor:`).

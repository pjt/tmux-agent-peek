#!/usr/bin/env bash
# tmux-agent-peek — find AI agent panes across all tmux sessions using only
# what the local tmux server can see (pane titles, foreground command, screen
# content), and jump to them. Works for agents reached through ssh, zmx,
# docker, mosh, … because their titles and screens flow into the local pane.
#
# No hooks, no ps, no remote calls. bash 3.2 compatible (macOS system bash).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
CLASSIFY="$HERE/classify.awk"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-peek"

# Foreground commands that are agents in their own right.
DEFAULT_CMD_PATTERN='^(claude|codex|opencode|aider|goose|gemini|kimi|kimi-code|pi)$'
# Titles that identify an agent regardless of foreground command. pi sets
# "π - <dir>" (or "π <glyph> <dir>" with extras/pi-title-state.ts); Claude
# Code sets "✳ <topic>" (and, reportedly, a braille spinner while working).
DEFAULT_TITLE_PATTERN='^π( |$)|^(✳|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|⠂|⠐) '
# Foreground commands that mean "the agent is on the other side of this".
DEFAULT_VIA_PATTERN='^(ssh|mosh|mosh-client|et|docker|podman|kubectl|zmx)$'
# Shells: a title match on a pane whose foreground is a local shell is a
# stale title left behind by an agent that already exited.
SHELL_PATTERN='^-?(bash|zsh|fish|sh|dash|ksh|tcsh|nu)$'

opt() { # opt <@option> <default>
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}

# ---------------------------------------------------------------- discovery

# One tmux call: every pane with the fields we need. Emits candidate agent
# panes, tab-separated, empty fields as "-" (bash `read` collapses runs of
# tabs, so fields must never be empty):
#   id kind via title_state session win_idx win_name title path attached stack server_pid
discover() {
  tmux list-panes -a -F \
    '#{pane_id}	#{pane_current_command}	#{pane_title}	#{session_name}	#{window_index}	#{window_name}	#{pane_current_path}	#{session_last_attached}	#{window_stack_index}	#{pid}' \
    2>/dev/null |
  awk -v cmdpat="$(opt @agent-peek-cmd-pattern "$DEFAULT_CMD_PATTERN")" \
      -v titlepat="$(opt @agent-peek-title-pattern "$DEFAULT_TITLE_PATTERN")" \
      -v viapat="$(opt @agent-peek-via-pattern "$DEFAULT_VIA_PATTERN")" \
      -v shellpat="$SHELL_PATTERN" '
    BEGIN { FS = OFS = "\t" }
    function nz(s) { return (s == "" ? "-" : s) }
    {
      id = $1; cmd = tolower($2); title = $3
      kind = ""
      if (cmd ~ cmdpat) {
        kind = cmd; sub(/-code$/, "", kind)
      } else if (title ~ titlepat) {
        if (cmd ~ shellpat) next              # stale title, agent exited
        if (title ~ /^π( |$)/)      kind = "pi"
        else if (title ~ /^(✳|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|⠂|⠐) /) kind = "claude"
        else                         kind = "agent"
      }
      if (kind == "") next
      via = (cmd ~ viapat) ? cmd : "-"

      # Title-state protocol: "<mark> <glyph> …" where glyph is one of
      # ▲ ✖ ■ ✻ ✔ ○ (see extras/pi-title-state.ts).
      ts = "-"
      split(title, tk, " ")
      if      (tk[2] == "▲") ts = "needs_input"
      else if (tk[2] == "✖") ts = "failed"
      else if (tk[2] == "■") ts = "stopped"
      else if (tk[2] == "✻") ts = "working"
      else if (tk[2] == "✔") ts = "completed"
      else if (tk[2] == "○") ts = "idle"

      print id, kind, via, ts, nz($4), nz($5), nz($6), nz(title), nz($7), nz($8), nz($9), nz($10)
    }'
}

# Capture every candidate pane's visible screen in ONE tmux invocation
# (~10ms for a dozen panes). If a pane vanished between discovery and capture
# tmux aborts the command sequence, so fall back to one call per pane.
capture() { # stdin: discover rows -> stdout: classify.awk input
  local id kind via rest args=()
  while IFS='	' read -r id kind via rest; do
    # display-message runs strftime on its format: "%30" must be "%%30"
    args+=(display-message -p "::peek:: %${id} $kind $via" ';' capture-pane -p -J -t "$id" ';')
  done
  [ "${#args[@]}" -gt 0 ] || return 0
  if ! tmux "${args[@]}" 2>/dev/null; then
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
      # groups of 10: display-message -p <hdr> ; capture-pane -p -J -t <id> ;
      tmux display-message -p "${args[$((i + 2))]}" 2>/dev/null
      tmux capture-pane -p -J -t "${args[$((i + 8))]}" 2>/dev/null
      i=$((i + 10))
    done
  fi
}

# ---------------------------------------------------------------- state

# Rows out of scan(), tab-separated, never empty:
#   1 pane_id  2 rank  3 status  4 session  5 win_idx  6 win_name  7 title
#   8 path  9 session_last_attached  10 window_stack_index  11 kind  12 via
#   13 source (title|screen|inferred)  14 matched_line
#
# Merges three inputs in one awk pass:
#   1. the previous scan's cache (per tmux server), for transition inference
#   2. screen classifications
#   3. discovered candidates
# and writes the new cache plus a transitions file for notify().
#
# State rules:
#   raw   = title state if the title carries one, else the screen state
#   if raw == previous raw: keep the previous final state (so a completed
#     that aged to idle stays idle)
#   else if raw is a screen "idle" and the previous final was
#     working/needs_input: completed (pi leaves no "done" marker on screen)
#   completed older than @agent-peek-completed-ttl ages to idle.
scan() {
  local cands screens server_pid cache new_cache trans ttl
  mkdir -p "$CACHE_DIR" 2>/dev/null
  cands="$(discover)"
  [ -n "$cands" ] || return 0
  screens="$(printf '%s\n' "$cands" | capture | awk -v TAIL="$(opt @agent-peek-tail 40)" -f "$CLASSIFY")"

  server_pid="$(printf '%s\n' "$cands" | head -n 1 | cut -f 12)"
  cache="$CACHE_DIR/state-$server_pid.tsv"
  new_cache="$cache.$$"
  trans="$CACHE_DIR/transitions.$$"
  ttl="$(opt @agent-peek-completed-ttl 1800)"
  [ -f "$cache" ] || : > "$cache"

  awk -v now="$(date +%s)" -v ttl="$ttl" -v newcache="$new_cache" -v trans="$trans" '
    BEGIN { FS = OFS = "\t" }
    FILENAME == ARGV[1] { pfinal[$1] = $2; psince[$1] = $3; praw[$1] = $4; next }
    FILENAME == ARGV[2] { sstate[$1] = $2; smatch[$1] = $3; next }
    {
      id = $1; kind = $2; via = $3; ts = $4
      ss = (id in sstate) ? sstate[id] : "idle"
      if (ss == "gone") next

      if (ts != "-") { raw = ts; src = "title" } else { raw = ss; src = "screen" }

      if ((id in praw) && raw == praw[id]) {
        final = pfinal[id]; since = psince[id]
        if (final != raw) src = "inferred"
      } else {
        final = raw; since = now
        if (src == "screen" && raw == "idle" && (id in pfinal) &&
            (pfinal[id] == "working" || pfinal[id] == "needs_input")) {
          final = "completed"; src = "inferred"
        }
      }
      if (final == "completed" && ttl > 0 && now - since >= ttl) final = "idle"

      print id, final, since, raw > newcache
      if ((id in pfinal) && final != pfinal[id] &&
          final ~ /^(needs_input|completed|failed|stopped)$/)
        print id, final, kind, via, $5, $6, $7 > trans

      rank = 5
      if (final == "needs_input") rank = 0
      else if (final == "failed") rank = 1
      else if (final == "stopped") rank = 2
      else if (final == "working") rank = 3
      else if (final == "completed") rank = 4
      m = (id in smatch) ? smatch[id] : "-"
      print id, rank, final, $5, $6, $7, $8, $9, $10, $11, kind, via, src, m
    }
  ' "$cache" <(printf '%s\n' "$screens") <(printf '%s\n' "$cands") |
    sort -t '	' -k2,2n -k9,9nr -k10,10n -k5,5n

  [ -f "$new_cache" ] && mv -f "$new_cache" "$cache" 2>/dev/null
  if [ -f "$trans" ]; then
    [ "${PEEK_NOTIFY:-0}" = 1 ] && notify < "$trans"
    rm -f "$trans"
  fi
  # drop caches from dead tmux servers
  find "$CACHE_DIR" -name 'state-*.tsv' -mtime +1 -delete 2>/dev/null
}

# ---------------------------------------------------------------- notify

# Owning .app bundle of a tmux client, found by walking its process ancestry.
term_app() {
  local pid="${1:-}" app
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    app="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "$app" in
      *.app/Contents/MacOS/*) printf '%s.app\n' "${app%%.app/Contents/MacOS/*}"; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

frontmost_app() {
  local asn
  asn="$(lsappinfo front 2>/dev/null)"
  [ -n "$asn" ] || return 1
  lsappinfo info -only bundlepath "$asn" 2>/dev/null |
    sed -n 's/.*"LSBundlePath"="\(.*\)".*/\1/p'
}

# stdin: transitions "id state kind via session win_idx win_name".
# Transitions are only detected when a scan runs — i.e. every status-interval
# via the status line — so banners lag by up to that interval.
notify() {
  [ "$(opt @agent-peek-notify on)" = on ] || return 0
  local id st kind via session win_idx win_name visible client_pid app title body exec_cmd tmux_bin
  tmux_bin="$(command -v tmux)"
  while IFS='	' read -r id st kind via session win_idx win_name; do
    visible="$(tmux display-message -p -t "$id" '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' 2>/dev/null)"
    client_pid="$(tmux list-clients -t "$session" -F '#{client_pid}' 2>/dev/null | head -n 1)"
    app=''
    [ -n "$client_pid" ] && app="$(term_app "$client_pid")"
    if [ "$visible" = 1 ] && [ -n "$app" ] && [ "$(frontmost_app)" = "$app" ]; then
      continue   # you're looking at it
    fi
    [ "$via" = "-" ] || kind="$kind via $via"
    case "$st" in
      needs_input) title='▲ needs input'; body="$kind is waiting for you" ;;
      completed)   title='✔ completed';   body="$kind finished its turn" ;;
      failed)      title='✖ failed';      body="$kind hit an error" ;;
      stopped)     title='■ stopped';     body="$kind was interrupted" ;;
      *) continue ;;
    esac
    title="$title · $session:$win_idx $win_name"
    if command -v terminal-notifier >/dev/null 2>&1; then
      exec_cmd="PATH=\"$(dirname "$tmux_bin"):\$PATH\"; '$SELF' jump '$id'"
      [ -n "$app" ] && exec_cmd="open '$app'; $exec_cmd"
      terminal-notifier -title "$title" -message "$body" -group "agent-peek-$id" \
        -sound default -execute "$exec_cmd" >/dev/null 2>&1 &
    elif command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"${body//\"/}\" with title \"${title//\"/}\" sound name \"default\"" \
        >/dev/null 2>&1 &
    else
      tmux display-message "agent-peek: $title — $body" 2>/dev/null
    fi
  done
}

# ---------------------------------------------------------------- rendering

# Display width: non-ASCII counts as 2 columns, except common narrow
# punctuation/symbols (…·—–‘’“”) which render 1 column wide.
dwidth() { # <str> -> sets DWIDTH_RESULT
  local wide="${1//[[:ascii:]]/}"
  wide="${wide//[…·—–‘’“”π]/}"
  DWIDTH_RESULT="$(( ${#1} + ${#wide} ))"
}

# Truncate to <width> display columns (… suffix), pad, and set FIT_RESULT.
fit() { # <str> <width> -> sets FIT_RESULT
  local s="$1" max="$2" w
  dwidth "$s"
  w="$DWIDTH_RESULT"
  if [ "$w" -gt "$max" ]; then
    while s="${s%?}"; do
      dwidth "$s"
      [ "$DWIDTH_RESULT" -le "$((max - 1))" ] && break
    done
    s="${s}…"
    dwidth "$s"
    w="$DWIDTH_RESULT"
  fi
  printf -v FIT_RESULT '%s%*s' "$s" "$((max - w))" ''
}

style() { # <status> -> sets STYLE_ICON, STYLE_LABEL, STYLE_COLOR
  case "$1" in
    needs_input) STYLE_ICON='▲'; STYLE_LABEL='needs input'; STYLE_COLOR=$'\033[1;33m' ;;
    failed)      STYLE_ICON='✖'; STYLE_LABEL='failed';      STYLE_COLOR=$'\033[1;31m' ;;
    stopped)     STYLE_ICON='■'; STYLE_LABEL='stopped';     STYLE_COLOR=$'\033[1;35m' ;;
    working)     STYLE_ICON='✻'; STYLE_LABEL='working';     STYLE_COLOR=$'\033[1;36m' ;;
    completed)   STYLE_ICON='✔'; STYLE_LABEL='completed';   STYLE_COLOR=$'\033[1;32m' ;;
    *)           STYLE_ICON='○'; STYLE_LABEL='idle';        STYLE_COLOR=$'\033[2m' ;;
  esac
}

# Read the current branch from Git's HEAD instead of spawning git per pane.
branch_for_path() { # <path> -> sets BRANCH_RESULT
  local path="$1" i=0 dir gitdir='' head
  while [ "$i" -lt "${#BRANCH_PATHS[@]}" ]; do
    if [ "${BRANCH_PATHS[$i]}" = "$path" ]; then
      BRANCH_RESULT="${BRANCH_NAMES[$i]}"; return 0
    fi
    i=$((i + 1))
  done
  BRANCH_RESULT=''
  dir="$path"
  while [ -n "$dir" ]; do
    if [ -d "$dir/.git" ]; then gitdir="$dir/.git"; break; fi
    if [ -f "$dir/.git" ]; then
      IFS= read -r gitdir < "$dir/.git" 2>/dev/null || gitdir=''
      case "$gitdir" in 'gitdir: '*) gitdir="${gitdir#gitdir: }" ;; *) gitdir='' ;; esac
      case "$gitdir" in /* | '') ;; *) gitdir="$dir/$gitdir" ;; esac
      break
    fi
    [ "$dir" = '/' ] && break
    dir="${dir%/*}"; [ -n "$dir" ] || dir='/'
  done
  if [ -n "$gitdir" ] && IFS= read -r head < "$gitdir/HEAD" 2>/dev/null; then
    case "$head" in
      'ref: refs/heads/'*) BRANCH_RESULT="${head#ref: refs/heads/}" ;;
      ?*)                  BRANCH_RESULT='HEAD' ;;
    esac
  fi
  BRANCH_PATHS[${#BRANCH_PATHS[@]}]="$path"
  BRANCH_NAMES[${#BRANCH_NAMES[@]}]="$BRANCH_RESULT"
}

# Strip the agent's own title decoration: "π - dev" -> "dev",
# "π ✻ name - dev" -> "name - dev", "✳ Fix login" -> "Fix login"; blank
# generic titles (hostnames, "user@host: path"). -> sets CLEAN_TITLE
clean_title() { # <title> <host> <hshort>
  local t="$1"
  [ "$t" = '-' ] && t=''
  case "$t" in
    'π - '*)  t="${t#π - }" ;;
    # alternation, not a [▲✖…] bracket: brackets match bytes under LANG=C
    'π ▲ '* | 'π ✖ '* | 'π ■ '* | 'π ✻ '* | 'π ✔ '* | 'π ○ '*)
              t="${t#π }"; t="${t#* }" ;;
    π)        t='' ;;
    '✳ '*)    t="${t#✳ }" ;;
  esac
  case "$t" in
    'Claude Code' | *@*:* | "$2" | "$3") t='' ;;
  esac
  CLEAN_TITLE="$t"
}

# Where the pane lives: branch+path for local agents; for agents behind
# ssh/zmx/docker the local cwd is meaningless, so say how it's reached.
place_for() { # <via> <path> -> sets PLACE_RESULT
  if [ "$1" != '-' ]; then
    PLACE_RESULT="⇄ via $1"
  else
    branch_for_path "$2"
    PLACE_RESULT="${BRANCH_RESULT:+⎇ $BRANCH_RESULT · }${2/#"$HOME"/\~}"
  fi
}

# Render scan rows as colored fzf lines: "pane_id \t <display>". Columns are
# sized to content (capped) in a first pass so everything lines up; title
# gives up space first if the popup is narrow.
render_list() {
  local host hshort buf
  local pane_id rank status session win_idx win_name title path attached stack kind via src m
  local session_w=0 winname_w=0 title_w=0 kind_w=0 place_w=0
  local session_cap=20 winname_cap=24 title_cap=60 kind_cap=10 place_cap=40
  local popup_cols overhead_w title_budget

  BRANCH_PATHS=(); BRANCH_NAMES=()
  host="$(hostname 2>/dev/null)"; hshort="${host%%.*}"

  buf="$(cat)"
  [ -z "$buf" ] && return 0

  while IFS='	' read -r pane_id rank status session win_idx win_name title path attached stack kind via src m; do
    clean_title "$title" "$host" "$hshort"
    place_for "$via" "$path"
    dwidth "$session:$win_idx"; [ "$DWIDTH_RESULT" -gt "$session_w" ] && session_w="$DWIDTH_RESULT"
    dwidth "$win_name";         [ "$DWIDTH_RESULT" -gt "$winname_w" ] && winname_w="$DWIDTH_RESULT"
    dwidth "$kind";             [ "$DWIDTH_RESULT" -gt "$kind_w" ]    && kind_w="$DWIDTH_RESULT"
    dwidth "$CLEAN_TITLE";      [ "$DWIDTH_RESULT" -gt "$title_w" ]   && title_w="$DWIDTH_RESULT"
    dwidth "$PLACE_RESULT";     [ "$DWIDTH_RESULT" -gt "$place_w" ]   && place_w="$DWIDTH_RESULT"
  done <<<"$buf"
  [ "$session_w" -gt "$session_cap" ] && session_w="$session_cap"
  [ "$winname_w" -gt "$winname_cap" ] && winname_w="$winname_cap"
  [ "$kind_w" -gt "$kind_cap" ] && kind_w="$kind_cap"
  [ "$place_w" -gt "$place_cap" ] && place_w="$place_cap"

  # here marker (2) + icon (2) + space (1) + label (11) + 5 gaps of 2 = 26
  overhead_w=26
  # tput must read the popup's tty, not our piped stdin.
  popup_cols="$( { tput cols < /dev/tty; } 2>/dev/null )"; popup_cols="${popup_cols:-100}"
  title_budget=$(( popup_cols - 2 - overhead_w - session_w - winname_w - kind_w - place_w ))
  [ "$title_budget" -lt 10 ] && title_budget=10
  [ "$title_w" -gt "$title_budget" ] && title_w="$title_budget"
  [ "$title_w" -gt "$title_cap" ] && title_w="$title_cap"

  while IFS='	' read -r pane_id rank status session win_idx win_name title path attached stack kind via src m; do
    local here label_col session_col winname_col kind_col title_col
    style "$status"
    clean_title "$title" "$host" "$hshort"
    place_for "$via" "$path"
    here='  '; [ "$pane_id" = "${AGENT_PEEK_CURRENT:-}" ] && here='◂ '
    printf -v label_col '%-11s' "$STYLE_LABEL"
    fit "$session:$win_idx" "$session_w"; session_col="$FIT_RESULT"
    fit "$win_name" "$winname_w";         winname_col="$FIT_RESULT"
    fit "$kind" "$kind_w";                kind_col="$FIT_RESULT"
    fit "$CLEAN_TITLE" "$title_w";        title_col="$FIT_RESULT"
    printf '%s\t%s%b%s %s\033[0m  \033[1m%s\033[0m  %s  \033[2m%s\033[0m  %s  \033[2m%s\033[0m\n' \
      "$pane_id" "$here" "$STYLE_COLOR" "$STYLE_ICON" "$label_col" \
      "$session_col" "$winname_col" "$kind_col" "$title_col" "$PLACE_RESULT"
  done <<<"$buf"
}

list() { scan | render_list; }

counts() { # -> "needs_input failed stopped working completed idle"
  scan | awk -F '\t' '{ c[$3]++ }
    END { printf "%d %d %d %d %d %d\n",
          c["needs_input"], c["failed"], c["stopped"],
          c["working"], c["completed"], c["idle"] }'
}

# status-right segment (tmux format markup). Also the poller: the status line
# is the only thing that runs scans unattended, so it's where transitions
# get noticed and notifications fire.
status_line() {
  local n f s w c i out=''
  read -r n f s w c i <<EOF
$(PEEK_NOTIFY=1 counts)
EOF
  [ "$((n + f + s + w + c + i))" -eq 0 ] && return 0
  [ "$n" -gt 0 ] && out="$out#[fg=yellow,bold]▲$n#[default] "
  [ "$f" -gt 0 ] && out="$out#[fg=red,bold]✖$f#[default] "
  [ "$s" -gt 0 ] && out="$out#[fg=magenta]■$s#[default] "
  [ "$w" -gt 0 ] && out="$out#[fg=cyan]✻$w#[default] "
  [ "$c" -gt 0 ] && out="$out#[fg=green]✔$c#[default] "
  [ "$i" -gt 0 ] && out="$out#[fg=colour244]○$i#[default] "
  printf '%s' "${out% }"
}

# Explain every candidate's classification — for tuning heuristics.
debug() {
  local only="${1:-}"
  printf 'pane\tstate\tsource\tkind\tvia\ttitle\tmatched\n'
  scan | awk -F '\t' -v only="$only" 'only == "" || $1 == only {
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $3, $13, $11, $12, $7, $14 }'
}

# ---------------------------------------------------------------- picker

picker() {
  local rows sel pane_id
  if ! command -v fzf >/dev/null 2>&1; then
    printf '\n   tmux-agent-peek needs fzf:  brew install fzf\n\n   press any key to close'
    read -rsn1; return 0
  fi
  rows="$(scan)"
  if [ -z "$rows" ]; then
    printf '\n   No agent panes found.\n\n   press any key to close'
    read -rsn1; return 0
  fi
  sel="$(printf '%s\n' "$rows" | render_list | fzf \
    --ansi --reverse --no-info --cycle \
    --delimiter='\t' --with-nth=2.. \
    --prompt='  ' --pointer='▌' \
    --header='enter jump · ctrl-r refresh · esc close' \
    --header-first \
    --color='header:dim,pointer:cyan,hl:cyan,hl+:cyan,bg+:236,gutter:-1,border:240' \
    --preview="tmux capture-pane -ep -t {1}" \
    --preview-window='bottom,55%,border-top' \
    --bind="ctrl-r:reload('$SELF' list)")" || return 0
  pane_id="${sel%%	*}"
  [ -n "$pane_id" ] && jump "$pane_id"
}

jump() { # <pane_id>
  local target session win_idx
  target="$(tmux display-message -p -t "$1" '#{session_name}:#{window_index}' 2>/dev/null)" || return 0
  session="${target%%:*}"; win_idx="${target##*:}"
  tmux select-pane -t "$1" 2>/dev/null
  tmux select-window -t "$session:$win_idx" 2>/dev/null
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$session" 2>/dev/null
  else
    # from outside tmux (notification click): retarget every client
    tmux list-clients -F '#{client_name}' 2>/dev/null |
    while IFS= read -r client; do
      tmux switch-client -c "$client" -t "$session" 2>/dev/null
    done
  fi
}

popup() {
  local w h cur
  w="$(opt @agent-peek-width 90%)"
  h="$(opt @agent-peek-height 75%)"
  cur="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
  tmux display-popup -E -b rounded -S 'fg=colour240' -T ' ◉ agents ' \
    -w "$w" -h "$h" "AGENT_PEEK_CURRENT='$cur' '$SELF' picker"
}

# ---------------------------------------------------------------- main

case "${1:-popup}" in
  scan)   scan ;;
  list)   list ;;
  counts) counts ;;
  status) status_line ;;
  debug)  debug "${2:-}" ;;
  raw)    discover | capture ;;   # classifier input, for fixtures/tuning
  picker) picker ;;
  jump)   jump "${2:?pane_id required}" ;;
  popup)  popup ;;
  *)      echo "usage: agent-peek.sh [popup|picker|list|counts|status|debug [pane_id]|raw|jump <pane_id>]" >&2; exit 1 ;;
esac

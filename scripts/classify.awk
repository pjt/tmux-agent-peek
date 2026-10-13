# tmux-agent-peek — screen classifier.
#
# Input: a stream of pane captures, each introduced by a header line
#   ::peek:: <pane_id> <kind> <via>
# followed by that pane's visible screen (tmux capture-pane -p -J).
#
# Output: one line per pane, tab-separated:
#   pane_id  state  matched_line  place
# place is where the agent says it is, read from its own UI ("-" if
# unknown). pi's footer puts "<cwd> (<branch>) • <session name>" on the line
# above its token/usage line; this matters for remote agents, whose local
# pane cwd is meaningless.
# state ∈ needs_input failed stopped working completed idle gone
#
# Rules (kept from tmux-agent-view's old scraper, extended for pi):
#   - Only the bottom TAIL non-blank lines are considered.
#   - The marker CLOSEST TO THE BOTTOM wins: a permission dialog below a
#     spinner reads needs_input; a fresh spinner below an old summary reads
#     working.
#   - "gone": for panes found by title through ssh/docker/a wrapper script
#     (via != "-"), the title may be stale: agents don't reset it on exit,
#     and they leave their last frame (footer included) on screen. So the
#     pane is gone if the agent's UI isn't visible OR the bottom line is a
#     shell prompt.
#
# macOS awk (20200816) is byte-oriented; multibyte glyphs are only used as
# literal alternations, which match correctly byte-for-byte.

BEGIN { if (TAIL == "") TAIL = 40 }

# "~/dev/web-api (spike/x) • support: timing" -> "⎇ spike/x · ~/dev/web-api"
function pi_place(l,   path, br) {
  sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
  sub(/ • .*$/, "", l)
  path = l; br = ""
  if (match(l, / \([^()]*\)$/)) {
    br = substr(l, RSTART + 2, RLENGTH - 3)
    path = substr(l, 1, RSTART - 1)
  }
  return (br != "" ? "⎇ " br " · " path : path)
}

function flush(   i, start, line, s, m, present) {
  if (id == "") return
  # trim trailing blank lines (unused screen rows)
  while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
  start = n - TAIL + 1; if (start < 1) start = 1
  s = ""; m = ""; present = 0; last = ""; place = ""
  for (i = start; i <= n; i++) {
    line = lines[i]
    if (line ~ /^[ \t]*$/) continue
    prev = last; last = line

    # ---- presence signatures (only consulted for remote panes)
    if (kind == "pi" && ((line ~ /↑[0-9]/ && line ~ /↓[0-9]/) || line ~ /[0-9.]+%\/[0-9.]+[kM]/)) {
      present = 1
      if (prev ~ /^ *(~|\/)/) place = pi_place(prev)
    }
    if (kind == "claude" && line ~ /for shortcuts|shift\+tab to cycle|esc to interrupt|⏵⏵|\[(Opus|Sonnet|Haiku)/) present = 1
    if (kind != "pi" && kind != "claude") present = 1

    # ---- needs input: permission dialog / plan approval / numbered choice.
    # Claude: "❯ 1."; Kimi: "▶ 1." + Approve/Reject.
    if (line ~ /Do you want|Would you like to proceed|[❯▶] [0-9]+\.|Approve for this session|Reject with feedback/) {
      s = "needs_input"; m = line; continue
    }
    # ---- failed: API/tool error ending the turn
    if (line ~ /API Error|Request timed out|OAuth token|Credit balance|overloaded_error|rate.?limit/ ||
        (kind == "pi" && line ~ /^ *Error: /)) {
      s = "failed"; m = line; continue
    }
    # ---- stopped: user interrupted
    if (line ~ /⎿ *Interrupted|Interrupted by user/ ||
        (kind == "pi" && line ~ /^ *Operation aborted/)) {
      s = "stopped"; m = line; continue
    }
    # ---- working: spinner word + "… (" (Claude, and pi with Claude-style
    # spinner extensions), the interrupt hint (Claude "esc to interrupt",
    # pi default "Working (esc to interrupt)"), braille/moon spinners (Kimi).
    # pi's other status lines are part of a run too: the auto-retry
    # countdown (pi clears its progress state while it waits), compaction,
    # branch summaries. pi 1.1 draws the spinner inside the editor's top
    # border ("── ✢ Manifesting… ───"); the "(12s)" elapsed time only
    # shows up some seconds into the turn.
    if (line ~ /to interrupt\)|esc to interrupt|(✻|✽|✶|✳|✢|✺|·) .*… ?\(/ ||
        (kind == "pi" && line ~ /^── (✻|✽|✶|✳|✢|✺|·|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏) .*(…|\.\.\.) ─/) ||
        (kind == "pi" && line ~ /Retrying \([0-9]+\/[0-9]+\) in [0-9]+s\.\.\.|(Compacting context|Auto-compacting|Summarizing branch)\.\.\. \(/) ||
        line ~ /(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏) (thinking|working)\.\.\./ ||
        line ~ /(🌑|🌒|🌓|🌔|🌕|🌖|🌗|🌘) ·/) {
      s = "working"; m = line; continue
    }
    # ---- completed: explicit end-of-turn marker. Claude: "✻ Worked for 1m 5s";
    # pi + Claude-style transcript extensions: "✻ Turn took 52s (…)". "!/…/"
    # keeps spinner lines like "(… · thought for 8s)" out. Stock pi has no
    # marker; its completions are inferred from working→idle transitions.
    if ((line ~ /(✻|✽|✶|✳|✢|✺) [A-Za-z]+ (for|took) [0-9]/ && line !~ /…/) || line ~ /※ recap:/) {
      s = "completed"; m = line; continue
    }
  }
  # Shell prompt on the bottom line, either
  #   - a prompt char ending the line ("❯", "bash-5.3$", "user@host:~$"), or
  #   - a prompt char at a word boundary followed by typed text
  #     ("❯ git status", "~/dev$ ls", "➜  repo"). Digits don't count as a
  #     boundary here, so footers like "CH99.2% $0.106" are not prompts.
  sub(/[ \t]+$/, "", last)
  if (via != "-" && (!present || last ~ /(\$|#|%|❯|➜|λ|»)$/ ||
                     last ~ /(^|[ :~\/\])])(\$|#|%|❯|➜|λ|») /)) { s = "gone"; m = "" }
  if (s == "") s = "idle"
  gsub(/\t/, " ", m); sub(/^[ \t]+/, "", m); sub(/[ \t]+$/, "", m)
  if (m == "") m = "-"
  gsub(/\t/, " ", place); if (place == "") place = "-"
  print id "\t" s "\t" m "\t" place
  id = ""; n = 0
}

/^::peek:: / {
  flush()
  id = $2; kind = $3; via = $4; n = 0
  next
}
{ lines[++n] = $0 }
END { flush() }

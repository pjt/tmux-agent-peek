# tmux-agent-peek — screen classifier.
#
# Input: a stream of pane captures, each introduced by a header line
#   ::peek:: <pane_id> <kind> <via>
# followed by that pane's visible screen (tmux capture-pane -p -J).
#
# Output: one line per pane, tab-separated:
#   pane_id  state  matched_line
# state ∈ needs_input failed stopped working completed idle gone
#
# Rules (kept from tmux-agent-view's old scraper, extended for pi):
#   - Only the bottom TAIL non-blank lines are considered.
#   - The marker CLOSEST TO THE BOTTOM wins: a permission dialog below a
#     spinner reads needs_input; a fresh spinner below an old summary reads
#     working.
#   - "gone": for panes reached through ssh/docker/etc. (via != "-") the
#     title may be stale after the agent exits, since the remote shell
#     usually doesn't reset it. If no sign of the agent's UI is on screen, we
#     report gone and the pane is dropped from the list.
#
# macOS awk (20200816) is byte-oriented; multibyte glyphs are only used as
# literal alternations, which match correctly byte-for-byte.

BEGIN { if (TAIL == "") TAIL = 40 }

function flush(   i, start, line, s, m, present) {
  if (id == "") return
  # trim trailing blank lines (unused screen rows)
  while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
  start = n - TAIL + 1; if (start < 1) start = 1
  s = ""; m = ""; present = 0
  for (i = start; i <= n; i++) {
    line = lines[i]
    if (line ~ /^[ \t]*$/) continue

    # ---- presence signatures (only consulted for remote panes)
    if (kind == "pi" && ((line ~ /↑[0-9]/ && line ~ /↓[0-9]/) || line ~ /[0-9.]+%\/[0-9.]+[kM]/)) present = 1
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
    if (line ~ /to interrupt\)|esc to interrupt|(✻|✽|✶|✳|✢|✺|·) .*… ?\(/ ||
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
  if (via != "-" && !present) { s = "gone"; m = "" }
  if (s == "") s = "idle"
  gsub(/\t/, " ", m); sub(/^[ \t]+/, "", m); sub(/[ \t]+$/, "", m)
  if (m == "") m = "-"
  print id "\t" s "\t" m
  id = ""; n = 0
}

/^::peek:: / {
  flush()
  id = $2; kind = $3; via = $4; n = 0
  next
}
{ lines[++n] = $0 }
END { flush() }

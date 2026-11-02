#!/usr/bin/env bash
# tmux-agent-peek — TPM / run-shell entry point

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$CURRENT_DIR/scripts/agent-peek.sh"

get_opt() {
  local v
  v="$(tmux show-option -gqv "$1")"
  printf '%s' "${v:-$2}"
}

key="$(get_opt @agent-peek-key 'a')"
tmux bind-key "$key" run-shell "$SCRIPT popup"

# Prepend the agent summary to status-right once (idempotent). The status
# line doubles as the poller that notices state changes and sends banners,
# so its refresh rate (status-interval) bounds notification latency.
if [ "$(get_opt @agent-peek-status 'on')" = "on" ]; then
  status_right="$(tmux show-option -gv status-right)"
  case "$status_right" in
    *agent-peek.sh*) ;;
    *) tmux set-option -g status-right "#($SCRIPT status) $status_right" ;;
  esac
fi

# Clicking the summary opens the popup. Any other click on the status line
# keeps tmux's default (switch to the clicked window).
if [ "$(get_opt @agent-peek-mouse 'on')" = "on" ]; then
  tmux bind-key -n MouseDown1Status if-shell -F \
    '#{==:#{mouse_status_range},agent-peek}' \
    "run-shell '$SCRIPT popup'" \
    'switch-client -t ='
fi

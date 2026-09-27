#!/usr/bin/env bash
# Classifier fixtures: tests/fixtures/<expected-state>--<description>.txt
# Each file is classify.awk input: a "::peek:: <id> <kind> <via>" header plus
# a screen capture. Make new ones from a live pane with:
#   scripts/agent-peek.sh raw   (then cut out the pane you want)
set -u
cd "$(dirname "$0")/.."
pass=0 fail=0
for f in tests/fixtures/*.txt; do
  name="$(basename "$f" .txt)"
  want="${name%%--*}"
  got="$(awk -f scripts/classify.awk "$f" | cut -f2)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (got %s)\n' "$name" "$got"
    awk -f scripts/classify.awk "$f" | cut -f3 | sed 's/^/        matched: /'
  fi
done
# Place (agent-reported cwd/branch) checks: fixture | expected 4th column
while IFS='|' read -r name want; do
  [ -n "$name" ] || continue
  got="$(awk -f scripts/classify.awk "tests/fixtures/$name.txt" | cut -f4)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    place %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  place %s (got %s, want %s)\n' "$name" "$got" "$want"
  fi
done <<'EOF'
completed--pi-via-dht-wrapper-48|⎇ feat/richer-status · ~/dev/web-api
completed--pi-via-dht-wrapper-49|⎇ main · ~/dev/data-query
idle--pi-over-ssh-zmx|~/dev
working--claude-spinner|-
EOF

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/bin/zsh
set -eu
cd "${0:A:h}/.."
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
day="$fixture/2026/11/17"
mkdir -p "$day"
# A five-hour cycle with a fresh origin and a terminal counter one minute before reset.
for sample in '1794917700 20' '1794924000 52' '1794934740 95'; do
    parts=(${=sample})
    printf '{"timestamp":%d,"type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":%d,"window_minutes":300,"resets_at":1794934800}}}}\n' "$parts[1]" "$parts[2]"
done > "$day/rollout-fixture.jsonl"
report=$(scripts/backtest-usage.sh "$fixture" 2026-11-18T00:00:00Z)
[[ "$report" == *'3 quota rows before deduplication'* && "$report" == *'Scored origins: 1 '* ]] || {
    print -u2 -- "$report"
    exit 1
}
print 'PASS backtest reads three rows and scores the fixture cycle'

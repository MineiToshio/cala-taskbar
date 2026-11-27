#!/bin/zsh
set -eu
if (( $# > 0 )); then
    if [[ "$1" == --backtest && $# -eq 2 && -x "${0:A:h}/backtest-usage.sh" ]]; then
        exec "${0:A:h}/backtest-usage.sh" "$2"
    fi
    print -u2 'Usage: scripts/check-usage.sh [--backtest <sessions-root>]'
    exit 2
fi
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-usage" \
    Sources/Cala/{Usage,UsagePace,UsageWindow,UsageJSON,UsagePaceHistory,UsageForecastTypes,UsageQuotaHistory,UsageCodexBackfill,UsageForecast}.swift \
    Sources/Cala/{CalendarText,AppPaths,Config,ClaudeStatusLine,ModulePlan}.swift \
    Checks/UsagePace/main.swift
"$out/cala-usage" "$out"

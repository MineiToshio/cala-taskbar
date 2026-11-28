#!/bin/zsh
set -eu

if (( $# < 1 || $# > 2 )); then
    print -u2 'Usage: scripts/backtest-usage.sh <sessions-root> [as-of-ISO8601]'
    exit 2
fi

# Resolve the caller's relative archive path before entering the repository.
sessions=${1:a}
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -O -module-cache-path "${CALA_MODULE_CACHE:-$work/modules}" -o "$work/cala-usage-backtest" \
    Sources/Cala/{UsageWindow,UsageJSON,UsagePaceHistory,CalendarText,UsageForecastTypes,UsageQuotaHistory,UsageCodexBackfill,Zstd,UsageForecast}.swift \
    Checks/UsageBacktest/main.swift
"$work/cala-usage-backtest" "$sessions" "$work/history" "${2:-}"

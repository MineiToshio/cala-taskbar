#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-usage-history" \
    Sources/Cala/{UsageWindow,UsageJSON,CalendarText,UsageForecastTypes,UsageQuotaHistory,UsageCodexBackfill,UsageForecast}.swift \
    Checks/UsageHistory/main.swift
"$out/cala-usage-history" "$out"

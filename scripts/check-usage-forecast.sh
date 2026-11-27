#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-usage-forecast" \
    Sources/Cala/{UsageWindow,CalendarText,UsageForecastTypes,UsageForecast}.swift \
    Checks/UsageForecast/main.swift
"$out/cala-usage-forecast"

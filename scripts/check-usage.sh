#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-usage" \
    Sources/Cala/{UsageWindow,UsageJSON,UsagePaceHistory,CalendarText}.swift Checks/UsagePace/main.swift
"$out/cala-usage"

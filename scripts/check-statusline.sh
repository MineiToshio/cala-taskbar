#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "${CALA_MODULE_CACHE:-$out/modules}" -o "$out/cala-statusline" \
    Sources/Cala/{ClaudeStatusLine,Config,ModulePlan,CalendarText,AppPaths}.swift Checks/ClaudeStatusLine/main.swift
"$out/cala-statusline"

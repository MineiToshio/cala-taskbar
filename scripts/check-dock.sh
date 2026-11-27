#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

file=Sources/Cala/DockRules.swift
if /usr/bin/grep -E '^[[:space:]]*import ' "$file" | /usr/bin/grep -qv '^import Foundation$'; then
    print -u2 "FAIL $file must only import Foundation"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-dock" "$file" Checks/DockRules/main.swift
"$out/cala-dock"

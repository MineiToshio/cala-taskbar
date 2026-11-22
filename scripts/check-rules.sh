#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

rules=(Sources/Cala/SystemRules.swift Sources/Cala/RestartRules.swift Sources/Cala/Formatting.swift)
for file in "${rules[@]}"; do
    if /usr/bin/grep -E '^[[:space:]]*import ' "$file" | /usr/bin/grep -qv '^import Foundation$'; then
        print -u2 "FAIL $file must only import Foundation"
        exit 1
    fi
done

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-rules" "${rules[@]}" \
    Sources/Cala/CalendarText.swift Checks/SystemRules/main.swift
"$out/cala-rules"

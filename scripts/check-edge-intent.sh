#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

for file in Sources/Cala/EdgeIntent.swift Sources/Cala/PanelPolicy.swift; do
    if /usr/bin/grep -E '^[[:space:]]*import ' "$file" | /usr/bin/grep -qv '^import Foundation$'; then
        print -u2 "FAIL $file must only import Foundation"
        exit 1
    fi
done

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-edge" \
    Sources/Cala/EdgeIntent.swift Sources/Cala/PanelPolicy.swift Checks/EdgeIntent/main.swift
"$out/cala-edge"

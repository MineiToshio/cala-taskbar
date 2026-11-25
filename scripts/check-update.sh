#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

policy=Sources/Cala/UpdatePolicy.swift
if /usr/bin/grep -E '^[[:space:]]*import ' "$policy" | /usr/bin/grep -qv '^import Foundation$'; then
    print -u2 "FAIL $policy must only import Foundation"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-update" "$policy" Checks/Update/main.swift
"$out/cala-update"

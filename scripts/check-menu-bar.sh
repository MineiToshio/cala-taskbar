#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

file=Sources/Cala/MenuBarGeometry.swift
if /usr/bin/grep -E '^[[:space:]]*import ' "$file" | /usr/bin/grep -qv '^import CoreGraphics$'; then
    print -u2 "FAIL $file must only import CoreGraphics"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "${CALA_MODULE_CACHE:-$out/modules}" -o "$out/cala-menu-bar" "$file" Checks/MenuBar/main.swift
"$out/cala-menu-bar"

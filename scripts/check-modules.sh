#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

plan=Sources/Cala/ModulePlan.swift
if /usr/bin/grep -E '^[[:space:]]*import ' "$plan" | /usr/bin/grep -qv '^import Foundation$'; then
    print -u2 "FAIL $plan must only import Foundation"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "${CALA_MODULE_CACHE:-$out/modules}" -o "$out/cala-modules" "$plan" Checks/Modules/main.swift
"$out/cala-modules"

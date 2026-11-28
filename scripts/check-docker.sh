#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

core=Sources/Cala/DockerCore.swift
if rg '^[[:space:]]*import ' "$core" | rg -qv '^import Foundation$'; then
    print -u2 "FAIL $core must only import Foundation"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
sources=("$core" Checks/Docker/main.swift)
defines=()
if [[ ${1:-} == --live || ${1:-} == --transport ]]; then
    sources+=(Sources/Cala/DockerService.swift)
    defines+=(-D DOCKER_CHECK)
fi
swiftc -O -module-cache-path "${CALA_MODULE_CACHE:-$out/modules}" "${defines[@]}" -o "$out/cala-docker" "${sources[@]}"
"$out/cala-docker" "$@"

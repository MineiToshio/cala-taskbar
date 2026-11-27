#!/bin/zsh
# Decode-only zstd reader: committed fixtures (made by the zstd CLI from generated inputs), damage handling and,
# when the zstd CLI is installed, a comparison on fresh inputs.
#   scripts/check-zstd.sh --regenerate   rewrites Checks/Zstd/fixtures with the installed zstd CLI
set -eu
cd "${0:A:h}/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-zstd" Sources/Cala/Zstd.swift Checks/Zstd/main.swift
fixtures=Checks/Zstd/fixtures
if [[ "${1:-}" == --regenerate ]]; then
    mkdir -p "$out/in" "$fixtures"
    "$out/cala-zstd" "$fixtures" --generate "$out/in"
    zstd -q -f -1 "$out/in/text" -o "$fixtures/text-1.zst"
    zstd -q -f -19 "$out/in/text" -o "$fixtures/text-19.zst"
    zstd -q -f -3 --zstd=wlog=10 "$out/in/text" -o "$fixtures/text-window-1k.zst"
    zstd -q -f -3 --no-check "$out/in/text" -o "$fixtures/text-no-check.zst"
    for name in random zeros empty tiny; do zstd -q -f -3 "$out/in/$name" -o "$fixtures/$name-3.zst"; done
fi
cli=$(command -v zstd || true)
if [[ -n "$cli" ]]; then "$out/cala-zstd" "$fixtures" --zstd "$cli"; else "$out/cala-zstd" "$fixtures"; fi

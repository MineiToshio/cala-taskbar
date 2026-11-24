#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

zones=(Sources/Cala/Zones/{ZoneModel,ZoneGeometry,ZonePicking,ZoneSnapping,ZoneTemplates,ZoneThumbnails,ZoneLinking,ZoneRestore,ZonesStore,ZoneDisplayKeys,ZoneDragMachine}.swift)
for file in "${zones[@]}" Sources/Cala/AppPaths.swift; do
    if /usr/bin/grep -E '^[[:space:]]*import ' "$file" | /usr/bin/grep -qvE '^import (Foundation|CoreGraphics)$'; then
        print -u2 "FAIL $file must only import Foundation or CoreGraphics"
        exit 1
    fi
done

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-zones" "${zones[@]}" \
    Sources/Cala/AppPaths.swift Checks/Zones/main.swift
"$out/cala-zones"

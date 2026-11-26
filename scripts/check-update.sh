#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

src=Sources/Cala
policy=$src/UpdatePolicy.swift
core=("$src"/Update{Version,Feed,Rules,Signature}.swift)
installer=$src/UpdateInstaller.swift
python3 - "$policy" "${core[@]}" "$installer" <<'PY'
import re, sys
from pathlib import Path
for name in sys.argv[1:]:
    path = Path(name)
    allowed = {"Foundation"}
    if path.stem == "UpdateSignature":
        allowed.add("CryptoKit")
    if path.stem == "UpdateInstaller":
        allowed.update(["Darwin", "Security"])
    source = path.read_text()
    for module in re.findall(r"^\s*(?:@\w+\s+|(?:public|internal|private)\s+)*import\s+(\w+)", source, re.M):
        if module not in allowed:
            sys.exit(f"FAIL {name}: import {module}")
PY
if /usr/bin/grep -nE '/usr/bin/lipo|xcrun|PlistBuddy' "${core[@]}" "$installer" "$policy"; then
    print -u2 "FAIL updater uses a development tool"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
compile=(swiftc -O -module-cache-path "$out/modules")
"${compile[@]}" -o "$out/cala-update" "$policy" Checks/Update/main.swift
"$out/cala-update"
"${compile[@]}" -o "$out/core" "${core[@]}" Checks/UpdateCore/main.swift
"$out/core"
"${compile[@]}" -D CALA_UPDATE_TEST -o "$out/install" "${core[@]}" "$installer" "$src/AppPaths.swift" Checks/UpdateInstall/main.swift
"$out/install" "$out/fixtures"

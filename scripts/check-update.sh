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
python3 - <<'PY'
import re, subprocess
from collections import defaultdict
from pathlib import Path

matches = subprocess.check_output([
    "/usr/bin/grep", "-RnE", "--include=*.swift",
    r"UpdateTestHook|updateTestHook|local\.cala\.test\.update|update-test-state\.json", "Sources",
], text=True)
references = defaultdict(set)
for match in matches.splitlines():
    file, line, _ = match.split(":", 2)
    references[Path(file)].add(int(line))

hook = Path("Sources/Cala/UpdateTestHook.swift")
for path in references.keys() | {hook}:
    branches = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        directive = re.fullmatch(r"\s*#(if|elseif|else|endif)\b\s*(.*?)\s*(?://.*)?", line)
        if directive:
            kind, condition = directive.groups()
            if kind == "if":
                branches.append(condition == "CALA_UPDATE_TEST")
            elif kind == "endif":
                branches.pop()
            else:
                branches[-1] = False
        elif (number in references[path] or (path == hook and line.strip())) and not any(branches):
            raise SystemExit(f"FAIL {path}:{number}: updater test hook outside #if CALA_UPDATE_TEST")
print("PASS updater test hook is conditionally compiled")
PY
compile=(swiftc -O -module-cache-path "${CALA_MODULE_CACHE:-$out/modules}")
"${compile[@]}" -o "$out/cala-update" "$policy" "$src/UpdateVersion.swift" Checks/Update/main.swift
"$out/cala-update"
"${compile[@]}" -o "$out/core" "${core[@]}" Checks/UpdateCore/main.swift
"$out/core"
"${compile[@]}" -D CALA_UPDATE_TEST -o "$out/install" "${core[@]}" "$installer" "$src/AppPaths.swift" "$src/Watchdog.swift" Checks/UpdateInstall/main.swift
"${compile[@]}" -D CALA_UPDATE_TEST -o "$out/fixture-helper" Sources/CalaUpdateHelper/main.swift
codesign --force --sign - --identifier local.cala.update "$out/fixture-helper"
"$out/install" "$out/fixtures" "$out/fixture-helper"

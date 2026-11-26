#!/bin/zsh
# Builds a test-only app, DMG and feed for the localhost fixture ladder.
set -euo pipefail

usage() {
  echo "Usage: $0 --out DIR --version V --build N --keys DIR [--corrupt sig|sha|size] [--crash-at-launch]" >&2
  exit 1
}

out= version= build= keys= corrupt= crash=0
while (( $# )); do
  case "$1" in
    --out|--version|--build|--keys|--corrupt)
      (( $# >= 2 )) || usage
      case "$1" in
        --out) out=$2 ;;
        --version) version=$2 ;;
        --build) build=$2 ;;
        --keys) keys=$2 ;;
        --corrupt) corrupt=$2; [[ "$corrupt" == sig || "$corrupt" == sha || "$corrupt" == size ]] || usage ;;
      esac
      shift 2 ;;
    --crash-at-launch) crash=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$out" && -n "$keys" && "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]] || usage
keys=${keys:A}
repo=${0:A:h:h}
out=$(python3 - "$out" "$repo" <<'PY'
from pathlib import Path
import sys

out, repo = (Path(arg).resolve() for arg in sys.argv[1:])
if out == repo or repo in out.parents:
    sys.exit("Fixture output must be outside the repository")
# The build and assets must also stay outside if the output already exists.
if any((out / name).is_symlink() for name in ("app", "latest.json", "manifest.json")):
    sys.exit("Fixture output contains symlinks")
print(out)
PY
)
cd "$repo"
commit=$(git rev-parse --verify HEAD)
public_key=$(<"$keys/public")
[[ -f "$keys/private.json" && "$public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]] ||
  { echo "Expected a throwaway key pair created by update-sign.swift testkey" >&2; exit 1; }

export CALA_BUILD_DIR="$out/app"
export CALA_VERSION="$version" CALA_BUILD_NUMBER="$build" CALA_SIGN_IDENTITY=-
export CALA_UPDATE_TEST=1 CALA_UPDATE_PUBLIC_KEYS="$public_key"
export CALA_UPDATE_FEED_URL=http://127.0.0.1:8765/latest.json
export CALA_UPDATE_TEST_UP_TIMEOUT=${CALA_UPDATE_TEST_UP_TIMEOUT:-30} CALA_UPDATE_TEST_CRASH_AT_LAUNCH="$crash"

./build.sh
./scripts/make-dmg.sh
dmg="$CALA_BUILD_DIR/Cala-$version.dmg"
mv -f "$dmg" "$out/${dmg:t}"
dmg="$out/${dmg:t}"
work=$(mktemp -d "${TMPDIR:-/tmp}/cala-fixture.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

python3 - "$CALA_BUILD_DIR/Cala.app" "$dmg" "$corrupt" "$work/manifest.json" "$commit" <<'PY'
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import plistlib
import sys

app, dmg, corrupt, output, commit = sys.argv[1:]
app, dmg = Path(app), Path(dmg)
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
manifest = {
    "schema": 1,
    "commit": commit,
    "bundleId": info["CFBundleIdentifier"],
    "version": info["CFBundleShortVersionString"],
    "build": int(info["CFBundleVersion"]),
    "minimumSystemVersion": info["LSMinimumSystemVersion"],
    "publishedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "dmg": {"url": f"http://127.0.0.1:8765/{dmg.name}",
            "size": dmg.stat().st_size + (corrupt == "size"),
            "sha256": "0" * 64 if corrupt == "sha" else sha256(dmg.read_bytes()).hexdigest()},
    "app": {"unpackedSize": sum(p.lstat().st_size for p in app.rglob("*")),
            "keychainHelperSHA256": sha256((app / "Contents/Helpers/cala-keychain").read_bytes()).hexdigest()},
    "notes": {"en": "Update test fixture.", "es": "Actualización de prueba."},
}
Path(output).write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
PY

swift -D CALA_UPDATE_TEST scripts/update-sign.swift sign --key "$keys/private.json" \
  --manifest "$work/manifest.json" --out "$work/latest.json"
if [[ "$corrupt" == sig ]]; then
  python3 - "$work/latest.json" <<'PY'
import base64
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
feed = json.loads(path.read_bytes())
signature = bytearray(base64.b64decode(feed["signature"]))
signature[0] ^= 1
feed["signature"] = base64.b64encode(signature).decode()
path.write_text(json.dumps(feed), encoding="utf-8")
PY
fi
mv -f "$work/latest.json" "$out/latest.json"
echo "Fixture: $dmg and $out/latest.json"

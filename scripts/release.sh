#!/bin/zsh
# Creates the universal DMG, checksum and signed update feed. Uploads nothing.
# CALA_SIGN_IDENTITY selects Developer ID signing; CALA_SKIP_NOTARIZE=1 skips notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

for var in ${(k)parameters}; do
  if [[ "$var" == CALA_UPDATE_* ]]; then
    echo "$var is set. Unset all CALA_UPDATE_* variables before releasing." >&2
    exit 1
  fi
done
[[ -z "${CALA_QA_REGULAR:-}" ]] || { echo "CALA_QA_REGULAR is for testing builds only" >&2; exit 1; }

BUILD_DIR=${CALA_BUILD_DIR:-build}
BUILD_DIR=${BUILD_DIR:a}
# With tracked changes, take the version, keys, notes and code from HEAD together.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "› uncommitted changes here: building $(git rev-parse --short HEAD) in a clean checkout"
  work=$(mktemp -d "${TMPDIR:-/tmp}/cala-release.XXXXXXXX")
  clean="$work/cala"
  trap 'git worktree remove --force "$clean" 2>/dev/null || true; rmdir "$work"' EXIT
  git worktree add --detach --quiet "$clean" HEAD
  CALA_BUILD_DIR="$clean/build" CALA_BUILD_NUMBER=${CALA_BUILD_NUMBER:-$(git rev-list --count HEAD)} "$clean/scripts/release.sh"
  version=$(tr -d '[:space:]' < "$clean/VERSION")
  mkdir -p "$BUILD_DIR"
  rm -rf "$BUILD_DIR/Cala.app"
  ditto "$clean/build/Cala.app" "$BUILD_DIR/Cala.app"
  cp "$clean/build/Cala-$version.dmg" "$clean/build/Cala-$version.dmg.sha256" "$clean/build/latest.json" "$BUILD_DIR/"
  echo "Release lista en $BUILD_DIR (desde el commit $(git rev-parse --short HEAD))"
  exit 0
fi

export CALA_VERSION=$(tr -d '[:space:]' < VERSION)
python3 - "$CALA_VERSION" <<'PY'
import re
import subprocess
import sys

version = sys.argv[1]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("VERSION must be numeric x.y.z")

def number(value):
    return tuple(map(int, value.split(".")))

tags = subprocess.check_output(["git", "tag", "--list", "v*"], text=True).splitlines()
versions = [(number(tag[1:]), tag) for tag in tags if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)]
if versions:
    highest, tag = max(versions)
    if number(version) <= highest:
        sys.exit(f"VERSION {version} must be newer than {tag}")
PY

notes_dir="docs/releases"
for lang in en es; do
  notes="$notes_dir/$CALA_VERSION.$lang.md"
  [[ -s "$notes" ]] || { echo "Missing release notes: $notes" >&2; exit 1; }
  (( $(wc -c < "$notes") <= 8192 )) || { echo "Release notes exceed 8 KB: $notes" >&2; exit 1; }
done
keys=packaging/update-public-keys
key="$HOME/.config/cala/update-signing-key.json"
[[ -n "$(tr -d '[:space:]' < "$keys")" && -f "$key" ]] ||
  { echo "Set up the release signing key first (docs/release.md)." >&2; exit 1; }

export CALA_SIGN_IDENTITY=${CALA_SIGN_IDENTITY:--}
[[ "$CALA_SIGN_IDENTITY" == "-" ]] && { echo "› free release: ad-hoc signed"; CALA_SKIP_NOTARIZE=1; }
[[ -n "${CALA_SENTRY_DSN:-}" ]] || echo "warning: CALA_SENTRY_DSN is not set; 'Report a problem' will be off in this build" >&2

for check in ./scripts/check-*.sh; do
  echo "› running ${check:t}"
  "$check"
done
echo "› checks passed"
./build.sh
APP="$BUILD_DIR/Cala.app"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$CALA_SIGN_IDENTITY" != "-" ]]; then
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q automation.apple-events || { echo "entitlements missing" >&2; exit 1; }
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/cala-release.XXXXXXXX")
mount="$work/mnt"
mounted=0
cleanup() {
  if (( mounted )); then
    hdiutil detach -quiet "$mount" || hdiutil detach -quiet -force "$mount" || return
  fi
  rm -rf "$work"
}
trap cleanup EXIT
if [[ -z "${CALA_SKIP_NOTARIZE:-}" ]]; then
  # Staple the app before making the disk image so the copied app can open offline.
  zip="$work/Cala-notarize.zip"
  ditto -c -k --keepParent "$APP" "$zip"
  ./scripts/notarize.sh "$zip"
  xcrun stapler staple "$APP"
fi

./scripts/make-dmg.sh
DMG="$BUILD_DIR/Cala-$CALA_VERSION.dmg"
if [[ -z "${CALA_SKIP_NOTARIZE:-}" ]]; then
  ./scripts/notarize.sh "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
  spctl -a -t exec -vv "$APP"
fi
shasum -a 256 "$DMG" > "$work/Cala.dmg.sha256"

python3 - "$APP" "$DMG" "$notes_dir" "$work/manifest.json" <<'PY'
from datetime import datetime, timezone
from hashlib import sha256 as digest
import json
from pathlib import Path
import plistlib
import sys

app, dmg, notes_dir, output = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
version = info["CFBundleShortVersionString"]
releases = "https://github.com/MineiToshio/cala-taskbar/releases"

def sha256(path):
    result = digest()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

size = dmg.stat().st_size
if not 0 < size <= 200_000_000:
    sys.exit("DMG exceeds the update size limit")
manifest = {
    "schema": 1,
    "bundleId": info["CFBundleIdentifier"],
    "version": version,
    "build": int(info["CFBundleVersion"]),
    "minimumSystemVersion": info["LSMinimumSystemVersion"],
    "publishedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "dmg": {"url": f"{releases}/download/v{version}/{dmg.name}", "size": size, "sha256": sha256(dmg)},
    "app": {"unpackedSize": sum(p.lstat().st_size for p in app.rglob("*")),
            "keychainHelperSHA256": sha256(app / "Contents/Helpers/cala-keychain")},
    "notes": {lang: (notes_dir / f"{version}.{lang}.md").read_text(encoding="utf-8") for lang in ("en", "es")},
    "notesURL": f"{releases}/tag/v{version}",
}
output.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
PY
swift scripts/update-sign.swift sign --key "$key" --manifest "$work/manifest.json" --out "$work/latest.json"
swift scripts/update-sign.swift verify --keys "$keys" --feed "$work/latest.json" --dmg "$DMG"

mkdir "$mount"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$DMG"
mounted=1
python3 - "$mount/Cala.app" "$keys" "$work/latest.json" <<'PY'
import base64
from hashlib import sha256
import json
from pathlib import Path
import plistlib
import sys

app, keys, feed = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
manifest = json.loads(base64.b64decode(json.loads(feed.read_bytes())["manifest"]))
expected = {
    "CalaUpdatePublicKeys": keys.read_text(encoding="utf-8").split(),
    "CalaUpdateFeedURL": "https://github.com/MineiToshio/cala-taskbar/releases/latest/download/latest.json",
    "CFBundleIdentifier": manifest["bundleId"],
    "CFBundleShortVersionString": manifest["version"],
    "CFBundleVersion": str(manifest["build"]),
    "LSMinimumSystemVersion": manifest["minimumSystemVersion"],
}
for key, value in expected.items():
    if info.get(key) != value:
        sys.exit(f"Unexpected {key} in the release DMG")
if any(key.startswith("CalaUpdateTest") for key in info):
    sys.exit("Release DMG contains test settings")
if sha256((app / "Contents/Helpers/cala-keychain").read_bytes()).hexdigest() != manifest["app"]["keychainHelperSHA256"]:
    sys.exit("Keychain helper SHA-256 differs from the manifest")
PY
hdiutil detach -quiet "$mount"
mounted=0
mv -f "$work/Cala.dmg.sha256" "$DMG.sha256"
mv -f "$work/latest.json" "$BUILD_DIR/latest.json"
echo "Release lista: $DMG, $DMG.sha256 y $BUILD_DIR/latest.json"

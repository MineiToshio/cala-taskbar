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

run_checks() {
  for check in ./scripts/check-*.sh; do
    echo "› running ${check:t}"
    "$check"
  done
  echo "› checks passed"
}

if [[ "${1:-}" == --checks-only && $# == 1 ]]; then
  # Isolate checks from ignored output, while letting a dry run test local edits.
  work=$(mktemp -d "${TMPDIR:-/tmp}/cala-release-checks.XXXXXXXX")
  trap 'rm -rf "$work"' EXIT
  git ls-files --cached --others --exclude-standard --deduplicate -z | python3 -c '
import shutil
import sys
from pathlib import Path
from os import fsdecode

root = Path(sys.argv[1])
for entry in sys.stdin.buffer.read().split(b"\0"):
    if not entry:
        continue
    source = Path(fsdecode(entry))
    if not (source.is_file() or source.is_symlink()):
        continue
    destination = root / source
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(source, destination, follow_symlinks=False)
' "$work"
  (cd "$work" && run_checks)
  exit 0
fi
checked_parent=
if [[ "${1:-}" == --checked-parent && $# == 3 ]]; then
  checked_parent=$2
  shift 2
fi
if (( $# > 1 )); then
  echo "Usage: $0 [commit] | --checks-only | --checked-parent <sha> <commit>" >&2
  exit 1
fi
commit=$(git rev-parse --verify --end-of-options "${1:-HEAD}^{commit}")
if [[ -n "$checked_parent" ]]; then
  # ship.sh checks the tree before building, including when resuming a release commit.
  version=$(git show "$commit:VERSION" | tr -d '[:space:]')
  [[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "VERSION must be numeric x.y.z" >&2; exit 1; }
  [[ "$(git rev-list --parents -n 1 "$commit")" == "$commit $checked_parent" ]] &&
    git diff --quiet "$checked_parent" "$commit" -- . ':(exclude)VERSION' \
      ":(exclude,literal)docs/releases/$version.en.md" ":(exclude,literal)docs/releases/$version.es.md" ||
    { echo "The release commit must change only VERSION and its notes since the checked parent." >&2; exit 1; }
fi
output=${CALA_BUILD_DIR:-build}
output=${output:a}
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

# Never build in the caller's tree, which may contain untracked or ignored source files.
echo "› building $commit in a clean checkout"
git clone --quiet --shared --no-checkout "$PWD" "$work/cala"
cd "$work/cala"
git checkout --quiet --detach "$commit"
export CALA_BUILD_DIR="$work/build"
BUILD_DIR="$CALA_BUILD_DIR"

CALA_VERSION=$(tr -d '[:space:]' < VERSION)
export CALA_VERSION
python3 - "$CALA_VERSION" "$commit" "$checked_parent" <<'PY'
import re
import subprocess
import sys

version, commit, checked_parent = sys.argv[1:]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("VERSION must be numeric x.y.z")

def number(value):
    return tuple(map(int, value.split(".")))

tags = subprocess.check_output(["git", "tag", "--list", "v*"], text=True).splitlines()
versions = []
for tag in tags:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        continue
    if checked_parent and tag == f"v{version}":
        tagged = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], text=True).strip()
        if tagged == commit:
            continue
    versions.append((number(tag[1:]), tag))
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

if [[ -z "$checked_parent" ]]; then
  run_checks
fi
./build.sh
APP="$BUILD_DIR/Cala.app"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$CALA_SIGN_IDENTITY" != "-" ]]; then
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q automation.apple-events || { echo "entitlements missing" >&2; exit 1; }
fi

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
(cd "$BUILD_DIR" && shasum -a 256 "${DMG:t}") > "$DMG.sha256"

python3 - "$APP" "$DMG" "$notes_dir" "$work/manifest.json" "$commit" <<'PY'
from datetime import datetime, timezone
from hashlib import sha256 as digest
import json
from pathlib import Path
import plistlib
import sys

app, dmg, notes_dir, output = map(Path, sys.argv[1:5])
commit = sys.argv[5]
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
    "commit": commit,
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
signer=(swift -module-cache-path "$work/modules" scripts/update-sign.swift)
needs_passphrase=0
if /usr/bin/security find-generic-password -s local.cala.update-signing -a update-signing-key.json -w 2>/dev/null |
  "${signer[@]}" sign --key "$key" --manifest "$work/manifest.json" --out "$work/latest.json" --passphrase-fd 0 2>&1 |
  /usr/bin/tee "$work/sign.log"; then
  :
else
  # A missing item sends EOF to the signer, which prompts on the controlling terminal.
  signing_pipeline=("${pipestatus[@]}")
  (( signing_pipeline[2] == 0 && signing_pipeline[3] == 0 )) || exit 1
  needs_passphrase=1
fi
if grep -Fq 'Saved Keychain passphrase did not unlock the key' "$work/sign.log"; then
  needs_passphrase=1
fi
"${signer[@]}" verify --keys "$keys" --feed "$work/latest.json" --dmg "$DMG"
mkdir "$mount"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$DMG"
mounted=1
"${signer[@]}" verify-release --keys "$keys" --feed "$work/latest.json" \
  --dmg "$DMG" --app "$mount/Cala.app" --tag "v$CALA_VERSION" --commit "$commit"
hdiutil detach -quiet "$mount"
mounted=0
mkdir -p "$output"
rm -rf "$output/Cala.app"
ditto "$APP" "$output/Cala.app"
cp "$DMG" "$DMG.sha256" "$work/latest.json" "$output/"
echo "Release lista en $output (commit $commit, tag v$CALA_VERSION)"
echo "CALA_RELEASE_COMMIT=$commit"
if (( needs_passphrase )); then
  if [[ -n "$checked_parent" ]]; then
    print 'CALA_RELEASE_NEEDS_PASSPHRASE=1'
  else
    print 'Guarda la frase una vez con ./scripts/ship.sh --save-passphrase / Save the passphrase once with ./scripts/ship.sh --save-passphrase'
  fi
fi

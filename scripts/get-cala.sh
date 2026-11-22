#!/bin/bash
# Installs (or updates) Cala from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/MineiToshio/cala-taskbar/main/scripts/get-cala.sh | bash
#
# It downloads the disk image, checks its SHA-256 against the one published with the release, copies Cala.app to
# /Applications (or ~/Applications when /Applications is not writable), and opens it. Files downloaded by curl are
# not marked as "downloaded from the internet", so macOS opens Cala without the one-time Gatekeeper block.
# Your settings are kept on update. Nothing else on your Mac is touched.
set -euo pipefail

REPO="MineiToshio/cala-taskbar"
BUNDLE_ID="local.cala"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Cala is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Cala needs macOS 14 (Sonoma) or later; this Mac has $(sw_vers -productVersion)."

# Where to download from: the latest release (overridable for testing).
if [[ -z "${CALA_DMG_URL:-}" ]]; then
  say "› Looking for the latest version…"
  json=$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest") \
    || fail "Could not reach GitHub. Check your connection, or download the DMG from https://github.com/$REPO/releases"
  CALA_DMG_URL=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  CALA_SHA_URL=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.dmg\.sha256"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [[ -n "$CALA_DMG_URL" && -n "$CALA_SHA_URL" ]] || fail "The latest release has no disk image. See https://github.com/$REPO/releases"
fi

tmp=$(mktemp -d)
mnt="$tmp/mnt"
cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

say "› Downloading $(basename "$CALA_DMG_URL")…"
curl -fL --progress-bar -o "$tmp/Cala.dmg" "$CALA_DMG_URL" || fail "Download failed."
curl -fsSL -o "$tmp/Cala.dmg.sha256" "$CALA_SHA_URL" || fail "Could not download the checksum."
expected=$(cut -d' ' -f1 < "$tmp/Cala.dmg.sha256")
actual=$(shasum -a 256 "$tmp/Cala.dmg" | cut -d' ' -f1)
[[ -n "$expected" && "$expected" == "$actual" ]] || fail "The download does not match its published checksum; nothing was installed."
say "› Checksum OK"

mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$tmp/Cala.dmg" || fail "Could not open the disk image."
[[ -d "$mnt/Cala.app" ]] || fail "The disk image does not contain Cala.app."
new_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$mnt/Cala.app/Contents/Info.plist")
[[ "$new_id" == "$BUNDLE_ID" ]] || fail "Unexpected app in the disk image ($new_id); nothing was installed."

if [[ -w /Applications ]]; then dest_dir=/Applications; else dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; fi
dest="$dest_dir/Cala.app"

# Quit a running Cala (a normal quit: it puts the Dock and menu bar back) before replacing it.
if pgrep -x Cala >/dev/null; then
  say "› Closing the running Cala…"
  pkill -x Cala || true
  for _ in $(seq 1 50); do pgrep -x Cala >/dev/null || break; sleep 0.1; done
fi
# Replace only a previous Cala, never anything else with that name.
if [[ -e "$dest" ]]; then
  old_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$dest/Contents/Info.plist" 2>/dev/null || true)
  [[ "$old_id" == "$BUNDLE_ID" ]] || fail "$dest exists and is not Cala; move it away and run this again."
  rm -rf "$dest"
fi

say "› Installing in $dest_dir…"
ditto "$mnt/Cala.app" "$dest"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$dest/Contents/Info.plist")
open "$dest"
say "✓ Cala $version is installed and open. Follow the welcome window to finish."

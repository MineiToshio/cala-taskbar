#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d "${TMPDIR:-/tmp}/cala-update-check.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
signer=scripts/update-sign.swift
helper=Sources/CalaUpdateHelper/main.swift
check=Checks/UpdateHelper/main.swift
swift=(swift -module-cache-path "$out/modules")
"${swift[@]}" "$signer" selftest
swiftc -O -D CALA_UPDATE_TEST -module-cache-path "$out/modules" -o "$out/cala-update" "$helper"
swiftc -O -module-cache-path "$out/modules" -o "$out/check" "$check"
"$out/check" "$out/cala-update" "$out"
# The watcher probes the old PID and sends only SIGTERM to an identified target.
signals=$(sed -nE 's/.*kill\([^,]+, *([^)]*)\).*/\1/p' "$helper" | sort -u)
[[ "$signals" == $'0\nSIGTERM' ]] || { echo "FAIL update helper signal policy" >&2; exit 1; }
echo "PASS update helper signal policy"

"${swift[@]}" "$signer" testkey "$out/keys"
printf 'fixture artifact' > "$out/Cala-1.1.0.dmg"
sum=$(shasum -a 256 "$out/Cala-1.1.0.dmg")
cat > "$out/manifest.json" <<JSON
{"schema":1,"bundleId":"local.cala","version":"1.1.0","build":131,"minimumSystemVersion":"14.0","publishedAt":"2026-12-01T10:00:00Z","dmg":{"url":"https://github.com/MineiToshio/cala-taskbar/releases/download/v1.1.0/Cala-1.1.0.dmg","size":16,"sha256":"${sum%% *}"},"app":{"unpackedSize":21000000,"keychainHelperSHA256":"${sum%% *}"},"notes":{"en":"Fixture","es":"Prueba"},"notesURL":"https://github.com/MineiToshio/cala-taskbar/releases/tag/v1.1.0"}
JSON
"${swift[@]}" -D CALA_UPDATE_TEST "$signer" sign --key "$out/keys/private.json" \
  --manifest "$out/manifest.json" --out "$out/latest.json"
"${swift[@]}" "$signer" verify --keys "$out/keys/public" --feed "$out/latest.json" --dmg "$out/Cala-1.1.0.dmg"

signature=Sources/Cala/UpdateSignature.swift
if [[ -f "$signature" ]]; then
  swiftc -O -D CALA_SIGNATURE_CROSSCHECK -module-cache-path "$out/modules" -o "$out/cross-check" \
    Sources/Cala/{UpdateVersion,UpdateFeed,UpdateSignature}.swift "$check"
  "$out/cross-check" "$out/keys/public" "$out/latest.json" "$out/manifest.json"
else
  echo "SKIP update-sign × UpdateSignature cross-check: $signature is absent (merge shard A)"
fi

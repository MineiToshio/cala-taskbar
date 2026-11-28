#!/bin/zsh
# Checks a copy of the Keychain helper against packaging/Helpers/cala-keychain.cdhash (used by build.sh):
#   scripts/verify-keychain-helper.sh HELPER [RECORD] [--cdhash]
#   scripts/verify-keychain-helper.sh --bundle APP
# HELPER mode requires the whole file's SHA-256 to match the recorded "sha256" line.
# --cdhash: additionally every slice reported by `lipo -archs` must have its own recorded line, and match it, and the
# record must not list slices the binary lacks. Any missing or empty line fails.
set -euo pipefail

verify_resigned_helper() (
  local reference=$1 helper=$2 tmp archs arch
  archs=$(lipo -archs "$reference")
  [[ "$archs" == "$(lipo -archs "$helper")" ]] || fail "Developer ID helper has different architectures from the committed helper"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cala-keychain-verify.XXXXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  for arch in ${=archs}; do
    lipo "$reference" -thin "$arch" -output "$tmp/reference-$arch"
    lipo "$helper" -thin "$arch" -output "$tmp/helper-$arch"
    chmod u+w "$tmp/reference-$arch" "$tmp/helper-$arch"
    /usr/bin/codesign --remove-signature "$tmp/reference-$arch" "$tmp/helper-$arch"
    if ! python3 - "$tmp/reference-$arch" "$tmp/helper-$arch" <<'PY'
import struct
import sys
from pathlib import Path

def executable_bytes(path):
    data = bytearray(Path(path).read_bytes())
    magic, _, _, _, commands, command_size, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xfeedfacf:
        raise ValueError("Expected a 64-bit little-endian Mach-O slice")
    offset = 32
    linkedit = []
    end = offset + command_size
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end or end > len(data):
            raise ValueError("Malformed Mach-O load commands")
        if command == 0x19 and size >= 72 and data[offset+8:offset+24] == b"__LINKEDIT".ljust(16, b"\0"):
            linkedit.append(offset)
        offset += size
    if offset != end or len(linkedit) != 1:
        raise ValueError("Expected one __LINKEDIT segment")
    # codesign can grow __LINKEDIT's VM size for a larger signature. Removing it
    # leaves that size in place, even though the signature bytes are gone.
    vm_size = linkedit[0] + 32
    data[vm_size:vm_size+8] = b"\0" * 8
    return data

sys.exit(executable_bytes(sys.argv[1]) != executable_bytes(sys.argv[2]))
PY
    then
      fail "Developer ID helper differs from the committed helper ($arch)"
    fi
  done
)

verify_bundle() (
  local app=$1 helper="$1/Contents/Helpers/cala-keychain" verifier=$2
  local reference="${verifier:h}/../packaging/Helpers/cala-keychain"
  local bundle_id app_id helper_id app_team helper_team
  signature_field() { /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n "s/^$2=//p"; }
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  app_id=$(signature_field "$app" Identifier)
  helper_id=$(signature_field "$helper" Identifier)
  [[ -n "$bundle_id" && "$app_id" == "$bundle_id" ]] || fail "app signing identifier $app_id != $bundle_id"
  [[ "$helper_id" == local.cala.keychain ]] || fail "helper signing identifier is ${helper_id:-missing}"
  app_team=$(signature_field "$app" TeamIdentifier)
  helper_team=$(signature_field "$helper" TeamIdentifier)
  [[ -n "$app_team" && "$helper_team" == "$app_team" ]] ||
    fail "Team ID mismatch: app ${app_team:-none}, helper ${helper_team:-none}"
  if [[ "$app_team" == "not set" ]]; then
    "$verifier" "$helper" --cdhash
  else
    # Developer ID replaces the committed signature. Verify the reference hash, then compare the stripped binaries.
    "$verifier" "$reference"
    verify_resigned_helper "$reference" "$helper"
  fi
)

fail() { print -u2 "Keychain helper check failed: $*"; exit 1; }
if [[ "${1:-}" == --bundle ]]; then
  verify_bundle "${2:?usage: $0 --bundle APP}" "${0:a}"
  exit 0
fi

helper=${1:?usage: $0 HELPER [RECORD] [--cdhash]}
record=${2:-$(dirname "$0")/../packaging/Helpers/cala-keychain.cdhash}
[[ "$record" == --cdhash ]] && { record=$(dirname "$0")/../packaging/Helpers/cala-keychain.cdhash; cdhash=1; } || cdhash=0
[[ "${3:-}" == --cdhash ]] && cdhash=1
[[ -f "$helper" ]] || fail "$helper is missing"
[[ -s "$record" ]] || fail "$record is missing or empty"

typeset -A rec
for line in "${(@f)$(<"$record")}"; do          # $(<…) also keeps a last line without a newline
  [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ "$line" =~ '^[a-z0-9_]+ [0-9a-f]{40,64}$' ]] || fail "malformed line in $record: $line"
  rec[${line%% *}]=${line#* }
done

[[ -n "${rec[sha256]:-}" ]] || fail "no sha256 line in $record"
sha=$(shasum -a 256 "$helper" | cut -d' ' -f1)
[[ "$sha" == "${rec[sha256]}" ]] || fail "sha256 $sha != recorded ${rec[sha256]} (not the committed helper)"

if (( cdhash )); then
  archs=(${=$(lipo -archs "$helper")})
  (( ${#archs} )) || fail "no slices in $helper"
  (( ${#rec} - 1 == ${#archs} )) || fail "$record lists $(( ${#rec} - 1 )) slices, $helper has ${#archs} (${archs[*]})"
  for arch in $archs; do
    expected=${rec[$arch]:-}
    [[ -n "$expected" ]] || fail "no cdhash recorded for $arch"
    actual=$(codesign -dvvv --arch "$arch" "$helper" 2>&1 | sed -n 's/^CDHash=//p')
    [[ -n "$actual" && "$actual" == "$expected" ]] || fail "$arch cdhash ${actual:-none} != recorded $expected"
  done
fi

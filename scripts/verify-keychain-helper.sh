#!/bin/zsh
# Checks a copy of the Keychain helper against packaging/Helpers/cala-keychain.cdhash (used by build.sh):
#   scripts/verify-keychain-helper.sh HELPER [RECORD] [--cdhash]
# Always: the whole file's SHA-256 must equal the recorded "sha256" line (the bytes are the committed ones).
# --cdhash: additionally every slice reported by `lipo -archs` must have its own recorded line, and match it, and the
# record must not list slices the binary lacks. Any missing or empty line fails.
set -euo pipefail
helper=${1:?usage: $0 HELPER [RECORD] [--cdhash]}
record=${2:-$(dirname "$0")/../packaging/Helpers/cala-keychain.cdhash}
[[ "$record" == --cdhash ]] && { record=$(dirname "$0")/../packaging/Helpers/cala-keychain.cdhash; cdhash=1; } || cdhash=0
[[ "${3:-}" == --cdhash ]] && cdhash=1
fail() { print -u2 "Keychain helper check failed: $*"; exit 1; }
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

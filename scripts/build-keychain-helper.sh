#!/bin/zsh
# (Re)builds packaging/Helpers/cala-keychain, the prebuilt Keychain helper that build.sh copies into Cala.app as-is.
#
#   !!! A rebuilt helper has a new cdhash. The Keychain trusts the helper by its cdhash, so EVERY user gets one more
#   !!! Mac-password prompt per mail account after the update that ships it. Only rebuild for a real reason (a bug in
#   !!! the helper, a new minimum macOS) and commit the binary and packaging/Helpers/cala-keychain.cdhash together.
#
#   scripts/build-keychain-helper.sh --yes       rebuild and re-sign the committed helper
#   scripts/build-keychain-helper.sh --test DIR  build TEST variants into DIR, never to be shipped: cala-keychain-test
#                                                (service "Cala Helper Test" in the keychain at CALA_KEYCHAIN_TEST_KEYCHAIN,
#                                                no caller check) and cala-keychain-probe* (caller check only)
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Helpers/cala-keychain/main.c
OUT=packaging/Helpers/cala-keychain
MIN_MACOS=14.0   # matches LSMinimumSystemVersion in build.sh and platforms in Package.swift

compile() { # out, extra flags...
  local out=$1; shift
  local tmp=$(mktemp -d) slices=()
  for arch in arm64 x86_64; do
    clang -O2 -Wall -Wextra -Werror -arch $arch -mmacosx-version-min=$MIN_MACOS "$@" \
      -framework Security -framework CoreFoundation -lbsm -o "$tmp/$arch" "$SRC"
    slices+=("$tmp/$arch")
  done
  lipo -create "${slices[@]}" -output "$out"
  rm -rf "$tmp"
}

case "${1:-}" in
  --test)
    dir=${2:?usage: $0 --test DIR}
    mkdir -p "$dir"
    compile "$dir/cala-keychain-test" -DCALA_KEYCHAIN_TEST
    compile "$dir/cala-keychain-probe" -DCALA_KEYCHAIN_CALLER_PROBE
    compile "$dir/cala-keychain-probe-team" -DCALA_KEYCHAIN_CALLER_PROBE '-DCALA_KEYCHAIN_TEST_TEAM="ABCDE12345"'
    compile "$dir/cala-keychain-probe-slow" -DCALA_KEYCHAIN_CALLER_PROBE -DCALA_KEYCHAIN_TEST_DELAY_MS=500
    compile "$dir/cala-keychain-probe-team-slow" -DCALA_KEYCHAIN_CALLER_PROBE -DCALA_KEYCHAIN_TEST_DELAY_MS=500 \
      '-DCALA_KEYCHAIN_TEST_TEAM="ABCDE12345"'
    compile "$dir/cala-keychain-probe-nouniq" -DCALA_KEYCHAIN_CALLER_PROBE -DCALA_KEYCHAIN_TEST_FAIL_UNIQ
    compile "$dir/cala-keychain-probe-team-nouniq" -DCALA_KEYCHAIN_CALLER_PROBE -DCALA_KEYCHAIN_TEST_FAIL_UNIQ \
      '-DCALA_KEYCHAIN_TEST_TEAM="ABCDE12345"'
    codesign --force --sign - --identifier local.cala.keychain.test "$dir/cala-keychain-test"
    for probe in probe probe-team probe-slow probe-team-slow probe-nouniq probe-team-nouniq; do
      codesign --force --sign - --options runtime --identifier local.cala.keychain.$probe "$dir/cala-keychain-$probe"
    done
    echo "Test helpers in $dir: cala-keychain-test (temp keychain, no caller check); cala-keychain-probe (caller check,"
    echo "then exit 0); suffixes: -team (as if signed by team ABCDE12345), -slow (waits 500 ms before checking),"
    echo "-nouniq (as if proc_pidinfo flavor 17 were unavailable)"
    ;;
  --yes)
    print -u2 "WARNING: this replaces the shipped Keychain helper. Every user will see one more Keychain prompt per mail account."
    mkdir -p "${OUT:h}"
    compile "$OUT"
    codesign --force --sign - --options runtime --identifier local.cala.keychain "$OUT"
    codesign --verify --strict "$OUT"
    {
      print "sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
      for arch in arm64 x86_64; do
        print "$arch $(codesign -dvvv --arch $arch "$OUT" 2>&1 | sed -n 's/^CDHash=//p')"
      done
    } > "$OUT.cdhash"
    scripts/verify-keychain-helper.sh "$OUT" "$OUT.cdhash" --cdhash
    echo "Built $OUT ($(lipo -archs "$OUT")). cdhashes:"; cat "$OUT.cdhash"; echo "Commit both files."
    ;;
  *)
    print -u2 "Refusing to rebuild the Keychain helper without --yes: every user would get another Keychain prompt."
    print -u2 "usage: $0 --yes | --test DIR"
    exit 1
    ;;
esac

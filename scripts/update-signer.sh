#!/bin/zsh
# Sourced by release, publish and ship. Return the cached signer path on stdout.
cached_update_signer() (
  local source=$1 cache="$HOME/Library/Caches/cala/tools"
  local source_hash swift_version hash signer lock_fd tmp
  local -A info
  umask 077
  mkdir -p -- "$cache" || return 1
  if [[ ! -d "$cache" || -L "$cache" || ! -O "$cache" ]] ||
     ! zmodload zsh/stat || ! zstat -H info -- "$cache" ||
     (( info[mode] & 8#022 )); then
    print -u2 -r -- "Unsafe signer cache: $cache"
    return 1
  fi
  source_hash=$(/usr/bin/shasum -a 256 < "$source") || return 1
  swift_version=$(swiftc --version 2>&1) || { print -u2 -r -- "$swift_version"; return 1; }
  hash=$(printf '%s\n%s\n' "$source_hash" "$swift_version" | /usr/bin/shasum -a 256) || return 1
  signer="$cache/update-sign-${hash%% *}"

  if [[ ! -f "$signer" || ! -x "$signer" ]]; then
    zmodload zsh/system &&
      touch "$signer.lock" &&
      zsystem flock -f lock_fd "$signer.lock" || return 1
    if [[ ! -f "$signer" || ! -x "$signer" ]]; then
      tmp=$(mktemp -d "$cache/.update-sign.XXXXXXXX") || return 1
      trap 'rm -rf -- "$tmp"' EXIT
      cp "$source" "$tmp/update-sign.swift" &&
        [[ "$(/usr/bin/shasum -a 256 < "$tmp/update-sign.swift")" == "$source_hash" ]] &&
        swiftc -O -module-cache-path "$tmp/modules" "$tmp/update-sign.swift" -o "$tmp/update-sign" >&2 &&
        mv -f -- "$tmp/update-sign" "$signer" || return 1
    fi
  fi
  print -r -- "$signer"
)

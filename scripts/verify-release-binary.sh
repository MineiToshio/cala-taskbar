#!/bin/zsh
# Sourced by release and ship so both check the same production binary.
verify_release_binary() (
  local strings_file
  strings_file=$(mktemp "${TMPDIR:-/tmp}/cala-release-strings.XXXXXXXX") || return 1
  trap 'rm -f -- "$strings_file"' EXIT
  /usr/bin/strings -arch all "$1" > "$strings_file" || return 1
  if /usr/bin/grep -Fn 'local.cala.test.update' "$strings_file"; then
    print -u2 "FAIL updater test notification is present in the release binary"
    return 1
  else
    (( $? == 1 )) || return 1
  fi
  print "PASS updater test notification is absent from the release binary"
)

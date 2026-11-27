#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

parser=Sources/Cala/MailMIME.swift
if /usr/bin/grep -E '^[[:space:]]*import ' "$parser" | /usr/bin/grep -qv '^import Foundation$'; then
    print -u2 "FAIL $parser must only import Foundation"
    exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-mail" \
    "$parser" Sources/Cala/{MailIMAP,MailService,MailKeychainAccess,MailOverlay,MailBodyCache,MailBodyStructure,MailSyncPlan,AppPaths,CalendarText}.swift Checks/MailParsing/main.swift Checks/MailParsing/MailFastChecks.swift
"$out/cala-mail"

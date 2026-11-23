#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Host self-test for the "never inside the repo" guard of
# scripts/ota/stage-device-certs.sh. Copies the script into a throwaway repo
# layout and stages a throwaway self-signed identity; nothing outside a temp
# directory is touched. Exit 0 when every case passes.
set -u

ROOT=$(git rev-parse --show-toplevel) || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
n=0

R="$T/repo"
mkdir -p "$R/scripts/ota" "$T/id" "$T/outside"
cp "$ROOT/scripts/ota/stage-device-certs.sh" "$R/scripts/ota/"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=selftest-device -days 1 \
    -keyout "$T/id/device.key" -out "$T/id/device.crt" >/dev/null 2>&1 || {
    echo "openssl could not create the test identity"; exit 1; }
ln -s "$R/staged" "$T/outside/link-into-repo"
ln -s "$R" "$T/repo-alias"

# case_ <expected: refuse|stage> <name> <script path> <--out>
case_() {
    n=$((n + 1))
    rm -rf "$R/staged" "$T/outside/real"
    mkdir -p "$R/staged"
    if HOME="$T/home" bash "$3" --ca "$T/id/device.crt" --cert "$T/id/device.crt" \
            --key "$T/id/device.key" --out "$4" >/dev/null 2>&1; then got=stage; else got=refuse; fi
    leaked=no
    [ -e "$R/staged/device.key" ] && leaked=yes
    if [ "$got" = "$1" ] && [ "$leaked" = no ]; then printf '  ok   %s\n' "$2"
    else printf '  FAIL %s (expected %s, got %s, key inside repo: %s)\n' "$2" "$1" "$got" "$leaked"
         fails=$((fails + 1)); fi
}

S="$R/scripts/ota/stage-device-certs.sh"
case_ refuse "--out inside the repo"                       "$S" "$R/staged"
case_ refuse "--out through an outside symlink into repo"  "$S" "$T/outside/link-into-repo"
case_ refuse "script run through a symlinked repo path"    "$T/repo-alias/scripts/ota/stage-device-certs.sh" "$R/staged"
case_ stage  "--out outside the repo"                      "$S" "$T/outside/real"

printf '%d cases, %d failed\n' "$n" "$fails"
[ "$fails" -eq 0 ]

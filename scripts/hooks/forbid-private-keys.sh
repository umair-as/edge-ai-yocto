#!/usr/bin/env bash
# Refuse to commit private-key material or anything under keys/.
#
# Defense-in-depth over .gitignore. `keys/` being ignored does not stop
# `git add -f`, and it does not stop a `git mv` of an already-tracked file
# into keys/ — rename detection classifies that as R, and the file stays
# tracked at its new path.
#
# Invoked by pre-commit (commit stage) with the staged file list as
# arguments; pre-commit stashes the worktree to its staged state first, so
# reading from disk here is reading staged content. Run standalone with no
# arguments and it derives the list itself.
#
# Override (only if you are certain) with: git commit --no-verify
set -euo pipefail

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    # ACMR (not AM): include rename/copy targets, so the git mv case above
    # cannot slip past the path guard.
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR)
fi

blocked=""
for f in "${files[@]}"; do
    [ -z "$f" ] && continue
    case "$f" in
        keys/*)
            blocked+="  $f  (under keys/)"$'\n' ;;
        *.key|*-key.pem|*.p12|*.pfx|*.jks|id_rsa|*/id_rsa|id_ed25519|*/id_ed25519)
            blocked+="  $f  (key-like name)"$'\n' ;;
    esac
    # Match the PEM armor line, not the bare words "PRIVATE KEY": this repo
    # tracks security docs and key-handling scripts that discuss keys in
    # prose, and a guard that blocks writing about keys gets disabled. The
    # armor form covers PKCS#8, RSA, EC, ENCRYPTED, and OPENSSH headers.
    # -a: a key pasted into an otherwise binary file still trips this.
    # Note: a DER/binary private key under an innocuous name evades the
    # content grep entirely — the keys/ path guard is the primary control
    # for that case, not this line.
    if [ -f "$f" ] && grep -qaE -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "$f" 2>/dev/null; then
        blocked+="  $f  (contains a PRIVATE KEY block)"$'\n'
    fi
done

if [ -n "$blocked" ]; then
    printf '\nCOMMIT BLOCKED — private-key / keys/ material is staged:\n%s\n' "$blocked" >&2
    printf 'Unstage it (git restore --staged <file>). Override only if certain: git commit --no-verify\n\n' >&2
    exit 1
fi

#!/bin/sh
# SPDX-License-Identifier: MIT
# Host self-test for scripts/hooks/check-commit-trailers.sh: accepted and
# refused commit messages. Exit 0 when every case passes.
set -u

ROOT=$(git rev-parse --show-toplevel) || exit 1
HOOK="$ROOT/scripts/hooks/check-commit-trailers.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
n=0

# case <expected: pass|fail> <name> <message>
case_() {
    n=$((n + 1))
    printf '%s\n' "$3" > "$T/msg"
    if "$HOOK" "$T/msg" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$1" ]; then printf '  ok   %s\n' "$2"
    else printf '  FAIL %s (expected %s, got %s)\n' "$2" "$1" "$got"; fails=$((fails + 1)); fi
}

OK='Assisted-by: claude-code:claude-opus-5-5'

case_ pass "plain Assisted-by" "fix(bsp): do a thing

Body.

$OK"
case_ pass "two models in order" "fix(bsp): do a thing

Assisted-by: claude-code:claude-sonnet-5
$OK"
case_ pass "model id with context suffix" "docs: x

Assisted-by: claude-code:claude-opus-5[1m]"
case_ pass "human Co-Authored-By is fine" "docs: x

Co-Authored-By: Jane Doe <jane@example.invalid>
$OK"
case_ pass "comment lines are ignored" "docs: x

$OK
# Please enter the commit message. scratch/notes.md
# Co-Authored-By: Claude <noreply@anthropic.com>"
case_ pass "diff below the scissors line is ignored" "docs: x

$OK
# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
diff --git a/scratch/x b/scratch/x
+Co-Authored-By: Claude <noreply@anthropic.com>"
case_ pass "fixup skips Assisted-by" "fixup! docs: x"
case_ pass "device user path /home/devel/ is not a leak" "docs: x

Runs as /home/devel/bin/x on the board.

$OK"
case_ pass "model id with a date tag" "docs: x

Assisted-by: claude-code:claude-opus-4-5@20251101"
case_ pass "build path is not a leak" "docs: x

Mentions build/<BOARD>/tmp only.

$OK"

case_ fail "AI Co-Authored-By" "docs: x

$OK
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
case_ fail "AI Co-Authored-By, lower case" "docs: x

$OK
co-authored-by: codex <codex@openai.com>"
case_ fail "bot Co-Authored-By" "docs: x

$OK
Co-Authored-By: some-tool[bot] <x@example.invalid>"
case_ fail "AI Co-Authored-By on a fixup" "fixup! docs: x

Co-Authored-By: Claude <noreply@anthropic.com>"
case_ fail "no Assisted-by" "docs: x

Body only."
case_ fail "Assisted-by in the body, not the trailer block" "docs: x

Assisted-by: claude-code:claude-opus-5-5

Trailing paragraph."
case_ fail "malformed Assisted-by" "docs: x

Assisted-by: Claude"
case_ fail "scratch path" "docs: x

See scratch/notes.md.

$OK"
case_ fail "host path on a line that also names /home/devel/" "docs: x

See /home/devel/foo and /home/someone/x.

$OK"
case_ fail "path traversal past /home/devel/" "docs: x

Ran /home/devel/../someone/x.

$OK"
case_ fail "host home path" "docs: x

Ran /home/someone/tool.

$OK"

printf '%d cases, %d failed\n' "$n" "$fails"
[ "$fails" -eq 0 ]

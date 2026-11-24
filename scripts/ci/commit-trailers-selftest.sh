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

# An Assisted-by trailer is no longer required; older commits carry one and pass.
OK='Signed-off-by: Jane Doe <jane@example.invalid>'

case_ pass "no trailers" "fix(bsp): do a thing

Body."
case_ pass "legacy Assisted-by is accepted" "fix(bsp): do a thing

Assisted-by: claude-code:some-model"
case_ pass "legacy malformed Assisted-by is not checked" "docs: x

Assisted-by: Claude"
case_ pass "human Co-Authored-By is fine" "docs: x

Co-Authored-By: Jane Doe <jane@example.invalid>
$OK"
case_ fail "comment line with a local path (kept by commit -m)" "docs: x

$OK
# see scratch/notes.md"
case_ pass "git's editor template naming a scratch branch and path" "docs: x

$OK
# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch fix/scratch/thing
# Changes to be committed:
#	new file:   scripts/scratch/x
#"
case_ pass "comment lines without leaks are ignored" "docs: x

$OK
# Please enter the commit message for your changes."
case_ pass "diff below the scissors line is ignored" "docs: x

$OK
# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
diff --git a/scratch/x b/scratch/x
+Co-Authored-By: Claude <noreply@anthropic.com>"
case_ pass "fixup" "fixup! docs: x"
case_ pass "device user path /home/devel/ is not a leak" "docs: x

Runs as /home/devel/bin/x on the board.

$OK"
case_ pass "build path is not a leak" "docs: x

Mentions build/<BOARD>/tmp only.

$OK"

case_ fail "AI Co-Authored-By" "docs: x

$OK
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
case_ fail "AI Co-Authored-By, lower case" "docs: x

$OK
co-authored-by: codex <codex@openai.com>"
case_ pass "Dependabot co-author is not an AI tool" "docs: x

$OK
Co-authored-by: dependabot[bot] <x@example.invalid>"
case_ fail "Copilot agent co-author" "docs: x

$OK
Co-authored-by: copilot-swe-agent[bot] <x@example.invalid>"
case_ fail "AI Co-Authored-By on a fixup" "fixup! docs: x

Co-Authored-By: Claude <noreply@anthropic.com>"
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

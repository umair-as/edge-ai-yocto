#!/bin/sh
# SPDX-License-Identifier: MIT
# Commit-message trailer and leak check (AGENTS.md "AI attribution").
#
#   check-commit-trailers.sh <message-file>
#
# Refuses: a Co-Authored-By line naming an AI tool; a message without an
# Assisted-by trailer of the form <tool>:<model-id>; a local working path
# (scratch/, a /home/<user>/ path; /home/devel/ is the device's own user).
# Merge, fixup!, squash! and amend!
# messages skip the Assisted-by requirement. Used by the commit-msg git hook
# and, per commit, by scripts/ci/repo-lint.sh.
set -u

msg=${1:?usage: check-commit-trailers.sh <message-file>}
AI_COAUTHOR='^co-authored-by:.*(claude|anthropic|codex|openai|copilot|kiro|gemini|cursor)'
ASSISTED='^Assisted-by: *[a-z][a-z0-9-]*:[A-Za-z0-9][A-Za-z0-9._@/-]*(\[[A-Za-z0-9]+\])?$'

# A commit -v message carries the diff below the scissors line, which git
# drops. '#' lines are kept by `git commit -m/-F` (cleanup=whitespace), so the
# leak and co-author checks read them too; only trailer parsing ignores them.
raw=$(sed '/^. -\{24\} >8 -\{24\}$/,$d' "$msg")
body=$(printf '%s\n' "$raw" | git stripspace --strip-comments)

rc=0
if printf '%s\n' "$raw" | grep -iqE "$AI_COAUTHOR"; then
    echo "commit-msg: AI Co-Authored-By trailer; use Assisted-by: <tool>:<model-id> instead" >&2
    rc=1
fi
leak=$(printf '%s\n' "$raw" | sed -E 's#/home/devel/([^.]|\.[^.])#\1#g' \
       | grep -nE '(^|[^A-Za-z0-9_.-])scratch/|/home/[a-z][a-z0-9_-]*/' || true)
if [ -n "$leak" ]; then
    printf 'commit-msg: local working path in the message:\n%s\n' "$leak" >&2
    rc=1
fi
case $(printf '%s\n' "$body" | head -n1) in
    'Merge '* | 'fixup! '* | 'squash! '* | 'amend! '*) exit "$rc" ;;
esac
trailers=$(printf '%s\n' "$body" | git interpret-trailers --parse)
if ! printf '%s\n' "$trailers" | grep -q '^Assisted-by:'; then
    echo "commit-msg: no Assisted-by: <tool>:<model-id> trailer (trailers go in the last paragraph, after a blank line)" >&2
    rc=1
elif printf '%s\n' "$trailers" | grep '^Assisted-by:' | grep -vqE "$ASSISTED"; then
    echo "commit-msg: malformed Assisted-by trailer; expected Assisted-by: <tool>:<model-id>" >&2
    rc=1
fi
exit "$rc"

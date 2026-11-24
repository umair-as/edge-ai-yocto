#!/bin/sh
# SPDX-License-Identifier: MIT
# Commit-message trailer and leak check (AGENTS.md "AI attribution").
#
#   check-commit-trailers.sh <message-file>
#
# Refuses: a Co-Authored-By line naming an AI tool; a local working path
# (scratch/, a /home/<user>/ path; /home/devel/ is the device's own user).
# Used by the commit-msg git hook and, per commit, by scripts/ci/repo-lint.sh.
set -u

msg=${1:?usage: check-commit-trailers.sh <message-file>}
AI_COAUTHOR='^co-authored-by:.*(claude|anthropic|codex|openai|copilot|kiro|gemini|cursor)'

# A commit -v message carries the diff below the scissors line, which git
# drops. '#' lines are kept by `git commit -m/-F` (cleanup=whitespace), so the
# leak and co-author checks read them too.
# git's own editor template (branch, status, file lists) is dropped first: it
# names branches and staged paths and is never recorded.
TEMPLATE='^#(	|$| (Please enter|Lines starting|with .#. will|On branch|Your branch|HEAD detached|Changes (to be|not staged)|Untracked files|You are|Author:|Date:|interactive rebase|Last command|Next command|No commands|It looks like|and try again|Explicit paths))'
raw=$(sed '/^. -\{24\} >8 -\{24\}$/,$d' "$msg" | grep -vE "$TEMPLATE" || true)

rc=0
if printf '%s\n' "$raw" | grep -iqE "$AI_COAUTHOR"; then
    echo "commit-msg: AI Co-Authored-By trailer; AI tools are not credited per commit (AGENTS.md \"AI attribution\")" >&2
    rc=1
fi
leak=$(printf '%s\n' "$raw" | sed -E 's#/home/devel/([^.]|\.[^.])#\1#g' \
       | grep -nE '(^|[^A-Za-z0-9_.-])scratch/|/home/[a-z][a-z0-9_-]*/' || true)
if [ -n "$leak" ]; then
    printf 'commit-msg: local working path in the message:\n%s\n' "$leak" >&2
    rc=1
fi
exit "$rc"

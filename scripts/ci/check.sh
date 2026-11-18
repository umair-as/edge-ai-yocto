#!/usr/bin/env bash
# Pre-PR gate: repository invariants, shellcheck and host selftests. No
# bitbake, no kas, no network. Run as `make check`; the last line is the
# RESULT line quoted in the PR body.
#
# Selftests that take tens of seconds run only when the tool they cover, or
# the selftest itself, differs from CHECK_BASE (default origin/main, else
# main), including uncommitted changes. CHECK_ALL=1 runs them unconditionally.
set -u

ROOT=$(git rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1

if [ -n "${CHECK_BASE:-}" ]; then
    BASE=$CHECK_BASE
elif git rev-parse --quiet --verify origin/main >/dev/null; then
    BASE=origin/main
else
    BASE=main
fi
failed=()
passed=0
skipped=()

step() {
    local name=$1; shift
    printf '\n== %s ==\n' "$name"
    if "$@"; then
        passed=$((passed + 1))
    else
        printf '  FAIL %s\n' "$name"
        failed+=("$name")
    fi
}

changed=""
if git rev-parse --quiet --verify "$BASE" >/dev/null; then
    changed=$(git diff --name-only "$(git merge-base "$BASE" HEAD)")
fi

# slow <name> <path-regex> <cmd…>: run when a matching path changed.
slow() {
    local name=$1 re=$2; shift 2
    if [ "${CHECK_ALL:-0}" = 1 ] || grep -qE "$re" <<<"$changed"; then
        step "$name" "$@"
    else
        skipped+=("$name")
    fi
}

run_shellcheck() {
    { git ls-files '*.sh'; git grep -lI -E '^#!.*(ba)?sh( |$)' -- ':!*.patch'; } \
        | sort -u | xargs shellcheck -S warning
}

# LINT_RANGE scopes the commit-trailer invariants to this branch.
step "repository invariants" env LINT_RANGE="${LINT_RANGE:-$BASE..HEAD}" scripts/ci/repo-lint.sh
step "private-key guard (all files)" pre-commit run forbid-private-keys --all-files
step "shellcheck" run_shellcheck
step "ModelPack host tests" python3 -m unittest -q scripts/modelpack/tests/test_modelpack.py
step "systemd-boot RAUC backend selftest" bash scripts/ci/edge-sdboot-backend-selftest.sh
slow "serial console tee selftest" \
    '^scripts/(dev/serial-console-tee\.py|ci/serial-console-tee-selftest\.py)$' \
    python3 scripts/ci/serial-console-tee-selftest.py
slow "VENTUNO Q flash tool selftest" \
    '^scripts/(dev/ventunoq-flash\.py|ci/ventunoq-flash-selftest\.py)$' \
    python3 scripts/ci/ventunoq-flash-selftest.py

printf '\n'
[ ${#skipped[@]} -gt 0 ] && printf 'skipped (unchanged): %s\n' "$(IFS=,; echo "${skipped[*]}")"
if [ ${#failed[@]} -eq 0 ]; then
    printf 'RESULT: make check passed (%d steps, base %s, HEAD %s)\n' \
        "$passed" "$BASE" "$(git rev-parse --short HEAD)"
    exit 0
fi
printf 'RESULT: make check FAILED: %s\n' "$(IFS=,; echo "${failed[*]}")"
exit 1

#!/bin/sh
# Text-only repository invariants. No bitbake, no kas, no network — seconds to
# run. A violation fails the run. Part of `make check` (scripts/ci/check.sh).
set -u

fail=0

hdr()  { printf '\n== %s ==\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
ok()   { printf '  ok   %s\n' "$1"; }

# ---------------------------------------------------------------- INVARIANTS

hdr "INVARIANT: wrynose override syntax (colons, not underscores)"
hits=$(git grep -nE '^[A-Z_]+_(append|prepend|remove)[ (]|^(RDEPENDS|DEPENDS|SRC_URI|FILES|RRECOMMENDS)_\$\{PN\}' \
       -- '*.bb' '*.bbappend' '*.inc' 2>/dev/null)
if [ -n "$hits" ]; then echo "$hits" | sed 's/^/    /'; bad "deprecated underscore override syntax"; else ok "none"; fi

hdr "INVARIANT: every tracked .patch declares Upstream-Status"
miss=0
for p in $(git ls-files '*.patch'); do
    grep -q '^Upstream-Status:' "$p" || { printf '    %s\n' "$p"; miss=1; }
done
[ "$miss" -eq 1 ] && bad "patch missing Upstream-Status (do_patch QA gate)" || ok "all declare it"

hdr "INVARIANT: no agent paths, host home paths or key material in shipped files"
# Excludes *.patch (payload belongs to upstream; rewriting it breaks context)
# and this script (it necessarily contains the patterns it searches for).
# /home/devel is the device's own user and is legitimate in target config.
files=$(git ls-files -- meta-edge-bsp meta-edge-distro kas scripts \
        | grep -vE '\.patch$|^scripts/ci/repo-lint\.sh$')
hits=""
[ -n "$files" ] && hits=$(grep -nE '\.claude/|scratch/|/home/[a-z]+/|BEGIN [A-Z ]*PRIVATE KEY' \
                          $files 2>/dev/null | grep -v '/home/devel/')
if [ -n "$hits" ]; then echo "$hits" | sed 's/^/    /'; bad "leaked agent path, host home path or key material"
else ok "clean"; fi

hdr "INVARIANT: no archives or prebuilt objects tracked"
# Vendor SDK archives and prebuilt libraries are supplied at build time.
hits=$(git ls-files | grep -E '\.(a|o|so(\.[0-9]+)*|ko|elf|zip|7z|rpm|deb|ipk|whl|tar|tgz|tar\.(gz|xz|bz2|zst))$')
if [ -n "$hits" ]; then echo "$hits" | sed 's/^/    /'; bad "archive or prebuilt object tracked"; else ok "none"; fi

hdr "INVARIANT: relative links in docs/ resolve"
broken=0
for f in $(git ls-files 'docs/*.md' '*.md'); do
    for l in $(grep -oE '\]\([^)#][^)]*\)' "$f" 2>/dev/null | sed 's/](\(.*\))/\1/' \
               | grep -vE '^https?://|^mailto:' | cut -d'#' -f1); do
        [ -z "$l" ] && continue
        [ -e "$(dirname "$f")/$l" ] || { printf '    %s -> %s\n' "$f" "$l"; broken=1; }
    done
done
[ "$broken" -eq 1 ] && bad "broken relative link" || ok "all resolve"

hdr "INVARIANT: no AI Co-Authored-By trailer on new commits"
# Scope: commits this branch adds, not all history. AGENTS.md grandfathers
# everything before 2026-08-12, and a rebase-merge rewrites committer dates,
# so a date filter on history is unreliable — the range is the honest scope.
RANGE="${LINT_RANGE:-main..HEAD}"
if git rev-parse --quiet --verify "${RANGE%%..*}" >/dev/null 2>&1; then
    hits=$(git log --no-merges "$RANGE" --format='%h %s%n%b' 2>/dev/null \
           | grep -iE '^Co-Authored-By:.*(claude|codex|copilot|kiro|bot)' || true)
    if [ -n "$hits" ]; then echo "$hits" | sed 's/^/    /'; bad "AI Co-Authored-By trailer in $RANGE"
    else ok "none in $RANGE"; fi
else
    ok "skipped (no base ref for $RANGE)"
fi

hdr "INVARIANT: new commits carry an Assisted-by trailer"
# Bot-authored commits (Dependabot, and any future [bot]-suffixed GitHub
# automation) have no AI participation to attest -- Assisted-by records AI
# tool involvement, not automated tooling. GitHub's own convention suffixes
# every bot account's name with "[bot]"; skip those.
if git rev-parse --quiet --verify "${RANGE%%..*}" >/dev/null 2>&1; then
    missing=0
    for c in $(git log --no-merges "$RANGE" --format='%H' 2>/dev/null); do
        case "$(git log -1 --format=%an "$c")" in
            *'[bot]') continue ;;
        esac
        git log -1 --format='%(trailers:key=Assisted-by,valueonly)' "$c" | grep -q . \
            || { printf '    %s %s\n' "$(git log -1 --format=%h "$c")" "$(git log -1 --format=%s "$c")"; missing=1; }
    done
    [ "$missing" -eq 1 ] && bad "commit without Assisted-by" || ok "all present"
else
    ok "skipped (no base ref)"
fi

hdr "RESULT"
[ "$fail" -eq 0 ] && { ok "invariants hold"; exit 0; }
printf '  invariant violation — see FAIL lines above\n'; exit 1

#!/bin/sh
# Text-only repository checks. No bitbake, no kas, no network — seconds to run.
#
# Two tiers:
#   INVARIANT — rules the tree satisfies today. A new violation fails the run.
#   ADVISORY  — rules the corpus does not yet satisfy. Reported, never fatal.
#
# Run locally with: scripts/ci/repo-lint.sh
set -u

RECIPE_DIRS="meta-edge-bsp meta-edge-distro"
fail=0

hdr()  { printf '\n== %s ==\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
warn() { printf '  warn %s\n' "$1"; }
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

# ------------------------------------------------------------------ ADVISORY

hdr "ADVISORY: private/link-local IPv4 addresses outside patch payload"
# Flags LAN-shaped addresses (RFC1918, link-local): the shape a bench host
# takes. A configurable RFC1918 default is fine and is reviewed by hand;
# loopback, public probe targets and dotted version strings are not matched.
ipf=$(git ls-files -- meta-edge-bsp meta-edge-distro kas scripts docs \
      | grep -vE '\.patch$|^scripts/ci/repo-lint\.sh$')
[ -n "$ipf" ] && grep -nE '(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168|169\.254)(\.[0-9]{1,3}){2}([^0-9.]|$)' \
    $ipf 2>/dev/null | grep -vE '/(8|12|16|24)([^0-9]|$)' | sed 's/^/  warn /'

hdr "ADVISORY: recipe metadata (recipe-metadata.md)"
for f in $(git ls-files "$(echo $RECIPE_DIRS | tr ' ' '\n' | head -1)/*.bb" 2>/dev/null; \
           git ls-files 'meta-edge-distro/*.bb' 2>/dev/null); do
    # A field may come from a require/include that lives in this repo.
    src="$f"
    for inc in $(sed -nE 's/^(require|include)[[:space:]]+([^[:space:]]+).*/\2/p' "$f" \
                 | sed 's|\${EDGE_BSP_LAYERDIR}|meta-edge-bsp|'); do
        for c in "$inc" "$(dirname "$f")/$inc"; do
            [ -f "$c" ] && { src="$src $c"; break; }
        done
    done
    m=""
    for v in SUMMARY DESCRIPTION HOMEPAGE SECTION LICENSE; do
        grep -q "^$v" $src || m="$m $v"
    done
    [ -n "$m" ] && warn "missing:$m  $f"
    awk -v F="$f" '/^SUMMARY[ \t]*=/ {gsub(/^[^"]*"|"[^"]*$/,"");
        if (length>80) printf "  warn SUMMARY %d chars (cap 80)  %s\n", length, F; exit}' "$f"
    # Longest single DESCRIPTION assignment (a one-line value closes on its
    # own line; per-package DESCRIPTION:<pkg> values count separately).
    n=$(awk '/^DESCRIPTION/ { c = 1; open = (gsub(/"/, "&") == 1) ; if (c > m) m = c; next }
             open { c++; if (c > m) m = c; if (/"[[:space:]]*$/) open = 0 }
             END { print m + 0 }' "$f")
    [ "$n" -gt 3 ] && warn "DESCRIPTION $n lines (cap 3)  $f"
done
hdr "ADVISORY: comment style (comment-style.md)"
# Comment lines only. Templates (*.example) address their reader and are
# skipped; `your-` placeholders, I2C/I²C and I/O are not first person. Dates
# are flagged only next to an observation word: pin and release dates are
# facts. docs/ paths are flagged in recipe and BitBake config files only.
csf=$( { git ls-files -- meta-edge-bsp meta-edge-distro kas scripts; echo Makefile; } \
      | grep -vE '\.(patch|example|png|svg|jpg|gz|bin|der|pem|crt)$|^scripts/ci/repo-lint\.sh$')
for f in $csf; do
    c=$(grep -nE '^[[:space:]]*#([^!]|$)' "$f" 2>/dev/null) || continue
    echo "$c" | sed 's/your-[a-z]*//g' \
        | grep -E '(^|[^A-Za-z])([Ww]e|[Oo]ur|[Yy]ou|[Yy]our)([^A-Za-z]|$)|(^|[^A-Za-z/])I([^A-Za-z0-9/²]|$)' \
        | sed "s|^|  warn first-person  $f:|"
    echo "$c" | grep -E '20[0-9]{2}-[01][0-9]-[0-3][0-9]' \
        | grep -iE 'observ|validat|measur|tested|bench|seen on' | sed "s|^|  warn dated        $f:|"
    echo "$c" | grep -E '[Ii]f you|[Ff]lip to|[Ww]hen you want' | sed "s|^|  warn directive    $f:|"
    case "$f" in
    *.bb|*.bbappend|*.bbclass|*.inc|*.cfg|*.conf|*.wks|*.wks.in)
        echo "$c" | grep -E 'docs/' | sed "s|^|  warn docs-path    $f:|"
        echo "$c" | grep -E '([^A-Za-z]|^)[Ss]hould([^A-Za-z]|$)' | sed "s|^|  warn directive    $f:|" ;;
    esac
done

hdr "ADVISORY: Makefile shape"
# Rationale over ~4 comment lines belongs in docs/; build settings reach
# bitbake through kas env:, not a hand-written passthrough list.
awk '/^[[:space:]]*#/ { if (!n) s = NR; n++; next }
     { if (n > 4) printf "  warn comment block %d lines  Makefile:%d\n", n, s; n = 0 }' Makefile
grep -n 'BB_ENV_PASSTHROUGH_ADDITIONS' Makefile | sed 's/^/  warn passthrough outside kas  Makefile:/'

printf '\n  Advisory findings never fail the run.\n'

hdr "RESULT"
[ "$fail" -eq 0 ] && { ok "invariants hold"; exit 0; }
printf '  invariant violation — see FAIL lines above\n'; exit 1

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
# and the scripts that necessarily contain the patterns they search for.
# /home/devel is the device's own user and is legitimate in target config.
files=$(git ls-files -- meta-edge-bsp meta-edge-distro kas scripts \
        | grep -vE '\.patch$|^scripts/ci/(repo-lint\.sh|commit-trailers-selftest\.sh)$|^scripts/hooks/check-commit-trailers\.sh$')
hits=""
LEAK_RE='\.claude/|scratch/|/home/[a-z]+/|BEGIN [A-Z ]*PRIVATE KEY'
# /home/devel/ is stripped per occurrence, not per line, so a second path on
# the same line (or ../ out of it) is still caught.
# shellcheck disable=SC2086
[ -n "$files" ] && hits=$(grep -nE "$LEAK_RE" $files 2>/dev/null \
                          | sed -E 's#/home/devel/([^.]|\.[^.])#\1#g' | grep -E "$LEAK_RE")
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

hdr "INVARIANT: recipe headers carry the required metadata"
# Recipe header rules (AGENTS.md task table): SUMMARY (<=80 chars), DESCRIPTION (<=3 lines), HOMEPAGE,
# SECTION, LICENSE, and LIC_FILES_CHKSUM unless LICENSE is CLOSED or the recipe
# is an image or bundle. A same-directory require/include counts. No
# BUGTRACKER pointing at this repository.
bad_rec=0
for f in $(git ls-files 'meta-edge-bsp/*.bb' 'meta-edge-distro/*.bb'); do
    d=$(dirname "$f")
    src="$f"
    for inc in $(sed -nE 's/^(require|include)[ \t]+([^ $]+)[ \t]*$/\2/p' "$f"); do
        [ -f "$d/$inc" ] && src="$src $d/$inc"
    done
    # shellcheck disable=SC2086
    m=$(cat $src | awk '
        /^(SUMMARY|DESCRIPTION|HOMEPAGE|SECTION|LICENSE|LIC_FILES_CHKSUM)[ \t]*[?:+.]*=/ {
            v = $1; sub(/[ \t?:+.=].*/, "", v); have[v] = 1 }
        /^SUMMARY[ \t]*=/ { s = $0
            while (s ~ /\\$/ && (getline nx) > 0) { sub(/\\$/, "", s); s = s nx }
            sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s)
            if (length(s) > 80) out = out " SUMMARY>80" }
        /^DESCRIPTION[ \t]*=/ { n = 1; while ($0 ~ /\\$/ && (getline) > 0) n++
            if (n > 3) out = out " DESCRIPTION>3-lines" }
        /^LICENSE[ \t]*=[ \t]*"CLOSED"/ { closed = 1 }
        $1 == "inherit" { for (i = 2; i <= NF; i++)
            if ($i ~ /^(image|core-image|edge-ab-image|bundle)$/) imgbundle = 1 }
        /^BUGTRACKER[ \t]*=.*umair-as\/edge-ai-yocto/ { out = out " internal-BUGTRACKER" }
        END {
            split("SUMMARY DESCRIPTION HOMEPAGE SECTION LICENSE", req, " ")
            for (i in req) if (!(req[i] in have)) out = out " no-" req[i]
            if (!("LIC_FILES_CHKSUM" in have) && !closed && !imgbundle) out = out " no-LIC_FILES_CHKSUM"
            print out }')
    [ -n "$m" ] && { printf '    %s:%s\n' "$f" "$m"; bad_rec=1; }
done
[ "$bad_rec" -eq 1 ] && bad "recipe header metadata (see the recipe header rules in AGENTS.md)" || ok "all recipes"

hdr "INVARIANT: new commit messages pass the trailer and leak check"
# Scope: commits this branch adds, not all history: older commits predate
# the rules. Same checker as the commit-msg hook. Bot-authored commits
# ("[bot]" suffix) are skipped.
RANGE="${LINT_RANGE:-main..HEAD}"
if git rev-parse --quiet --verify "${RANGE%%..*}" >/dev/null 2>&1; then
    msgf=$(mktemp)
    bad_msg=0
    for c in $(git log --no-merges "$RANGE" --format='%H' 2>/dev/null); do
        case "$(git log -1 --format=%an "$c")" in
            *'[bot]') continue ;;
        esac
        git log -1 --format=%B "$c" > "$msgf"
        if ! why=$(scripts/hooks/check-commit-trailers.sh "$msgf" 2>&1); then
            printf '    %s %s\n' "$(git log -1 --format=%h "$c")" "$(git log -1 --format=%s "$c")"
            printf '%s\n' "$why" | sed 's/^/      /'
            bad_msg=1
        fi
    done
    rm -f "$msgf"
    [ "$bad_msg" -eq 1 ] && bad "commit message check in $RANGE" || ok "all pass in $RANGE"
else
    ok "skipped (no base ref for $RANGE)"
fi

hdr "RESULT"
[ "$fail" -eq 0 ] && { ok "invariants hold"; exit 0; }
printf '  invariant violation — see FAIL lines above\n'; exit 1

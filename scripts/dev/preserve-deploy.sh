#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Copy a board's deploy directory to build/deploy-preserved/<board>-<label>/
# before a rebuild replaces it, so the old DTB, UKIs and bundle stay
# comparable (scripts/dev/dtb-diff.py).
#
# Only regular files are copied. The kernel's versioned DTB names and the
# image link names in deploy are symlinks to the latest build: a copied
# symlink points at nothing, and a dereferenced one can carry an old version
# in its name with the new build's content. LINKS records each link name and
# the file it resolved to at copy time.
#
# Default: boot and update artifacts (DTBs, overlays, UKIs, kernel Image,
# bundle, manifests, verity parameters). --all also copies root filesystem
# images, module tarballs and vmlinux.
#
#   scripts/dev/preserve-deploy.sh [--all] <board> <label>

set -euo pipefail

all=0
if [ "${1:-}" = "--all" ]; then
    all=1
    shift
fi
if [ $# -ne 2 ]; then
    sed -n '/^# Copy/,/^#   scripts/s/^# \{0,1\}//p' "$0" >&2
    exit 2
fi
board=$1
label=$2
case "$label" in
    *[!A-Za-z0-9._-]* | '') echo "preserve-deploy: label must match [A-Za-z0-9._-]+" >&2; exit 2 ;;
esac

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
images="$root/build/$board/tmp/deploy/images"
[ -d "$images" ] || { echo "preserve-deploy: no deploy directory: $images" >&2; exit 1; }
dest="$root/build/deploy-preserved/$board-$label"
[ -e "$dest" ] && { echo "preserve-deploy: $dest exists" >&2; exit 1; }

keep() {
    [ "$all" = 1 ] && return 0
    case "$1" in
        *.dtb | *.dtbo | *.efi | *.efi.stub | *.raucb | *.manifest | *.json | \
            *.verity-params | *.verity-info | Image | Image-* | Image.gz*) return 0 ;;
    esac
    return 1
}

copied=0
links=()
while IFS= read -r -d '' src; do
    rel=${src#"$images"/}
    keep "$(basename "$rel")" || continue
    if [ -L "$src" ]; then
        if [ -e "$src" ]; then
            links+=("$rel -> $(realpath --relative-to="$(dirname "$src")" "$src")")
        else
            links+=("$rel -> (dangling) $(readlink "$src")")
        fi
        continue
    fi
    mkdir -p "$dest/$(dirname "$rel")"
    cp --preserve=timestamps "$src" "$dest/$rel"
    copied=$((copied + 1))
done < <(find "$images" -mindepth 2 \( -type f -o -type l \) -print0 | sort -z)

[ "$copied" -gt 0 ] || { echo "preserve-deploy: nothing matched in $images" >&2; exit 1; }
if [ "${#links[@]}" -gt 0 ]; then printf '%s\n' "${links[@]}"; fi > "$dest/LINKS"
sums=$(cd "$dest" && find . -type f ! -name SHA256SUMS ! -name LINKS -print0 | sort -z | xargs -0 sha256sum)
printf '%s\n' "$sums" > "$dest/SHA256SUMS"
echo "preserve-deploy: $copied file(s), ${#links[@]} link name(s) -> $dest"

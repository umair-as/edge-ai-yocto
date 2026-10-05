#!/usr/bin/env bash
# Operator-run Yocto check for one commit, reported as GitHub commit statuses.
#
# Checks out the commit as a detached git worktree outside the repo (the
# committed tree, never the working tree), seeds it with the host overlay, runs
# a parse matrix and optionally an image + bundle build per board, and posts one
# commit status per stage:
#
#   yocto/pins            every composed repo pinned by commit; resolved == declared
#   yocto/parse           `make parse` matrix (quick | full)
#   yocto/image-<board>   `make dev BOARD=<board>`          (--build only)
#   yocto/bundle-<board>  `make bundle BOARD=<board>`       (--build only)
#
# Nothing runs unless the operator runs this. Hosted CI stays text-only
# (.github/workflows/lint.yml); this is the Yocto half, on a host that has
# the layer and sstate caches.
#
#   scripts/ci/local-check.sh                       # origin/main, quick matrix, post statuses
#   scripts/ci/local-check.sh --ref pr/16           # a PR head; status lands in the PR checks
#   scripts/ci/local-check.sh --matrix full         # + every optional capability fragment
#   scripts/ci/local-check.sh --build rzv2l         # + image and bundle for one board
#   scripts/ci/local-check.sh --no-status           # dry run, nothing posted
#
# Host overlay: kas/ci-local.yml from the main checkout when present, else
# kas/local.yml (both gitignored). Without either, parse works but a build
# runs with cold caches. keys/ is linked into the worktree for --build so the
# artefacts are signed with the same dev keys as operator builds.
#
# Logs: <workdir>/logs/<sha7>/<cell>.log. Artefacts: <workdir>/artifacts/<sha7>/.
# The worktree (and its build/) is removed at exit unless --keep.
# A build already running on the host is refused: one bitbake at a time.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

REF=origin/main
MATRIX=quick
BUILD_BOARDS=()
POST=1
KEEP=0
WORKDIR="${EDGE_CI_WORKDIR:-/var/tmp/edge-ci}"
BOARDS=(rzv2l raspberrypi5)
# Dev-tier parse per optional fragment / make flag; see `make help`.
FULL_FLAGS=("TPM=1" "JTAG=1" "BPF=1" "NETBOOT=1" "OPTEE_EXAMPLES=1" "SBOM_TUNE=1"
            "EDGE_BOOT_TARGET=emmc" "ACCEL=none")

while [ $# -gt 0 ]; do
    case $1 in
        --ref)       REF=$2; shift ;;
        --matrix)    MATRIX=$2; shift ;;
        --build)     IFS=, read -r -a BUILD_BOARDS <<<"$2"; shift ;;
        --no-status) POST=0 ;;
        --keep)      KEEP=1 ;;
        --workdir)   WORKDIR=$2; shift ;;
        -h|--help)   usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done
case $MATRIX in quick|full) ;; *) echo "--matrix must be quick or full" >&2; exit 1 ;; esac
for b in "${BUILD_BOARDS[@]}"; do
    [ -f "kas/machines/$b.yml" ] || { echo "unknown board: $b" >&2; exit 1; }
done

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

# Host resources, not directory locks: a second bitbake on this host is refused
# even for another board. Shell wrappers whose command line merely mentions a
# bitbake path are not builds.
running=$(pgrep -af 'bin/(bitbake|bitbake-server|kas)( |$)' | grep -vE '^[0-9]+ \S*sh -c ' || true)
if [ -n "$running" ]; then
    echo "a bitbake/kas process is already running on this host:" >&2
    echo "$running" | head -3 | sed 's/^/  /' >&2
    exit 1
fi

if [ "$POST" -eq 1 ]; then
    command -v gh >/dev/null || { echo "gh not found; use --no-status" >&2; exit 1; }
    SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner) \
        || { echo "gh cannot resolve the repo; use --no-status" >&2; exit 1; }
fi

# ---------------------------------------------------------------- checkout

git fetch -q origin
case $REF in
    pr/*) git fetch -q origin "refs/pull/${REF#pr/}/head"; SHA=$(git rev-parse FETCH_HEAD) ;;
    *)    SHA=$(git rev-parse --verify "$REF^{commit}") ;;
esac
SHORT=${SHA:0:7}
WT=$WORKDIR/wt-$SHORT
LOGS=$WORKDIR/logs/$SHORT
ART=$WORKDIR/artifacts/$SHORT
mkdir -p "$LOGS"

cleanup() {
    if [ "$KEEP" -eq 0 ] && [ -d "$WT" ]; then
        git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
        git worktree prune
    fi
}
# A previous --keep run, or a directory git no longer tracks as a worktree.
if [ -d "$WT" ]; then
    git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
fi
git worktree prune
git worktree add -q --detach "$WT" "$SHA"
trap cleanup EXIT

if [ -f kas/ci-local.yml ]; then
    cp kas/ci-local.yml "$WT/kas/local.yml"; OVERLAY=kas/ci-local.yml
elif [ -f kas/local.yml ]; then
    cp kas/local.yml "$WT/kas/local.yml"; OVERLAY=kas/local.yml
else
    OVERLAY="(none — cold caches)"
fi
# keys/ is gitignored host material and parse needs it already: rauc-conf
# lists the dev CA cert in SRC_URI, and bitbake checksums SRC_URI files at
# parse time. Builds additionally sign with the same keys as operator builds.
if [ -d keys ]; then
    ln -s "$ROOT/keys" "$WT/keys"
else
    echo "warn: no keys/ in $ROOT — run scripts/rauc-init-certs.sh first; parse will fail on rauc-conf" >&2
fi

# The main checkout's direnv/.envrc exports KAS_WORK_DIR and KAS_BUILD_DIR for
# its own tree. Inherited here they would make the worktree's kas reset the
# main checkout's layer clones to this commit's pins. KAS_REPO_REF_DIR stays:
# alternates are read-only.
unset KAS_WORK_DIR KAS_BUILD_DIR
export KAS_WORK_DIR="$WT/.kas"
mkdir -p "$KAS_WORK_DIR"
# Same default as the Makefile. Absent, kas clones every layer from upstream
# instead of from local alternates — correct, but slow and network-bound.
export KAS_REPO_REF_DIR="${KAS_REPO_REF_DIR:-/mnt/yocto-nvme/layers-wrynose}"
if [ -d "$KAS_REPO_REF_DIR" ]; then refdir=present; else
    refdir="MISSING — layers clone from upstream"; fi

echo "commit   $SHA ($REF)"
echo "worktree $WT"
echo "overlay  $OVERLAY"
echo "refdir   $refdir"
echo "matrix   $MATRIX${BUILD_BOARDS[*]:+  build: ${BUILD_BOARDS[*]}}"
echo "logs     $LOGS"
echo

# ---------------------------------------------------------------- helpers

# status <context> <state> <description>; description is capped by GitHub at 140.
status() {
    [ "$POST" -eq 1 ] || return 0
    gh api -X POST "repos/$SLUG/statuses/$SHA" \
        -f state="$2" -f context="$1" -f description="${3:0:140}" >/dev/null \
        || echo "warn: could not post status $1" >&2
}

FAILED=()
# cell <name> <make args…>: one make invocation in the worktree, logged to
# <name>.log; prints one line; records the name on failure.
cell() {
    local name=$1 log="$LOGS/$1.log" start rc=0 err
    shift
    start=$(date +%s)
    make -C "$WT" "$@" >"$log" 2>&1 || rc=$?
    if [ $rc -eq 0 ]; then
        printf 'ok   %-32s %4ds\n' "$name" $(( $(date +%s) - start ))
    else
        # bitbake: "ERROR: …"; kas: "<timestamp> - ERROR - …"; make: "*** …".
        err=$(grep -m1 -E '^ERROR|ERROR +- |^\*\*\* ' "$log" | sed -E 's/^.* - ERROR +- //' || true)
        err=${err//$HOME/\~}
        printf 'FAIL %-32s %4ds  %s\n' "$name" $(( $(date +%s) - start )) "${err:0:80}"
        FAILED+=("$name")
    fi
    return $rc
}

mins() { echo $(( ($(date +%s) - $1 + 30) / 60 )); }

# ---------------------------------------------------------------- pins

# A repo given only by branch resolves to a different commit from one day to
# the next; `--resolve-refs` shows what kas actually checked out. Both dumps
# must agree, and every repo must carry a commit. The two dumps run in
# sequence: kas serialises on its own lock.
status yocto/pins pending "checking kas pins"
t0=$(date +%s)
pins_ok=1
for b in "${BOARDS[@]}"; do
    stack="kas/base.yml:kas/machines/$b.yml"
    declared=$( (cd "$WT" && kas dump "$stack" 2>>"$LOGS/pins.log") | grep -E '^\s+commit:' | sort)
    resolved=$( (cd "$WT" && kas dump --resolve-refs "$stack" 2>>"$LOGS/pins.log") | grep -E '^\s+commit:' | sort)
    if [ "$declared" != "$resolved" ]; then
        pins_ok=0
        { echo "== $b: declared vs resolved"; diff <(echo "$declared") <(echo "$resolved"); } >>"$LOGS/pins.log" || true
    fi
done
if [ $pins_ok -eq 1 ]; then
    printf 'ok   %-32s %4ds\n' pins $(( $(date +%s) - t0 ))
    status yocto/pins success "all composed repos pinned; resolved == declared"
else
    printf 'FAIL %-32s %4ds  see pins.log\n' pins $(( $(date +%s) - t0 ))
    FAILED+=(pins)
    status yocto/pins failure "a composed repo floats or drifted from its pin"
fi

# ---------------------------------------------------------------- parse

cells=()
for b in "${BOARDS[@]}"; do
    cells+=("parse-$b-dev|parse BOARD=$b EDGE_PROFILE=dev" "parse-$b-prod|parse BOARD=$b EDGE_PROFILE=prod")
    if [ "$MATRIX" = full ]; then
        for f in "${FULL_FLAGS[@]}"; do
            cells+=("parse-$b-dev-${f%%=*}=${f#*=}|parse BOARD=$b EDGE_PROFILE=dev $f")
        done
    fi
done
total=${#cells[@]}
[ "$MATRIX" = full ] && total=$((total + 1))
status yocto/parse pending "$MATRIX matrix: $total parses running"
t0=$(date +%s)
parse_fail=0
for c in "${cells[@]}"; do
    # shellcheck disable=SC2086  # the make args are a deliberate word list
    cell "${c%%|*}" ${c#*|} || parse_fail=$((parse_fail + 1))
done
# The public composition: no host overlay at all (`make` appends kas/local.yml
# only when present).
if [ "$MATRIX" = full ]; then
    [ -f "$WT/kas/local.yml" ] && mv "$WT/kas/local.yml" "$WT/kas/local.yml.off"
    cell parse-rzv2l-dev-nolocal parse BOARD=rzv2l EDGE_PROFILE=dev || parse_fail=$((parse_fail + 1))
    [ -f "$WT/kas/local.yml.off" ] && mv "$WT/kas/local.yml.off" "$WT/kas/local.yml"
fi
if [ $parse_fail -eq 0 ]; then
    status yocto/parse success "$MATRIX $total/$total ok · $(mins "$t0")m"
else
    failed_parse=$(printf '%s\n' "${FAILED[@]}" | grep '^parse-' | sed 's/^parse-//' | paste -sd, -)
    status yocto/parse failure "$MATRIX $((total - parse_fail))/$total · FAIL $failed_parse"
fi

# ---------------------------------------------------------------- build

for b in "${BUILD_BOARDS[@]}"; do
    mkdir -p "$ART/$b"
    status "yocto/image-$b" pending "make dev BOARD=$b"
    t0=$(date +%s)
    if cell "image-$b-dev" dev "BOARD=$b"; then
        status "yocto/image-$b" success "edge-image-dev built · $(mins "$t0")m"
    else
        status "yocto/image-$b" failure "edge-image-dev failed"
        status "yocto/bundle-$b" error "skipped: image failed"
        continue
    fi
    status "yocto/bundle-$b" pending "make bundle BOARD=$b"
    t0=$(date +%s)
    if cell "bundle-$b" bundle "BOARD=$b"; then
        status "yocto/bundle-$b" success "edge-bundle built · $(mins "$t0")m"
    else
        status "yocto/bundle-$b" failure "edge-bundle failed"
    fi
    # A fresh worktree has no build/conf, so the Makefile builds in
    # build/<board>/ for every board. Current artefacts are the unversioned
    # symlinks; copy their targets.
    deploy=$(find "$WT/build/$b/tmp/deploy/images" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    if [ -n "$deploy" ]; then
        find "$deploy" -maxdepth 1 -type l \
            \( -name '*.raucb' -o -name '*.wic*' -o -name '*.manifest' -o -name 'fitImage*' \) \
            -exec cp -L {} "$ART/$b/" \;
    fi
    grep -hE 'Sstate summary|Tasks Summary' "$LOGS/image-$b-dev.log" "$LOGS/bundle-$b.log" \
        >"$ART/$b/build-summary.txt" 2>/dev/null || true
    echo "artefacts $ART/$b"
done

# ---------------------------------------------------------------- result

echo
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "RESULT ok  $SHORT"
else
    echo "RESULT FAIL $SHORT  ${FAILED[*]}"
    exit 1
fi

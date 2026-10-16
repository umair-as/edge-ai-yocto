#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# C-level regression test for slot hooks on RAUC's boot-emmc handler. Builds the
# RAUC source in a temp dir twice, stock and with the layer's backport of the
# upstream fix (rauc a75bbb2b; RAUC_PATCH=<file> tests another patch), adds
# scripts/ci/rauc-boot-emmc-hooks/boot_emmc_hooks.c as a glib test linked
# against librauc, and runs RAUC's real handler with emmc_shim.so standing in
# for the eMMC (EXT_CSD ioctls, BLKGETSIZE64, force_ro sysfs).
#
#   scripts/ci/rauc-boot-emmc-hooks-test.sh <rauc-1.15.2.tar.xz | rauc git dir>
#
# A git dir is read with `git archive v1.15.2` (nothing in it changes). Expected:
# stock fails the hook cases (the bug), patched passes all. Needs meson, ninja,
# a C compiler and RAUC's build dependencies (glib, openssl, curl, json-glib,
# libnl, dbus). Exit 0 when both expectations hold.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="${1:-}"
PATCH="${RAUC_PATCH:-$ROOT/meta-edge-bsp/recipes-core/rauc/files/0001-src-update_handler-fix-assertion-slot-name-failed-er.patch}"
TDIR="$ROOT/scripts/ci/rauc-boot-emmc-hooks"
[ -n "$SRC" ] || { sed -n '12,13p' "$0" | sed 's/^# //'; exit 2; }
[ -f "$PATCH" ] || { echo "missing $PATCH" >&2; exit 2; }
for t in meson ninja cc; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

W=$(mktemp -d); [ -n "${KEEP:-}" ] && echo "workdir kept: $W" || trap 'rm -rf "$W"' EXIT
extract() {
    mkdir -p "$1"
    if [ -d "$SRC/.git" ] || git --git-dir="$SRC" rev-parse >/dev/null 2>&1; then
        git -C "$SRC" archive v1.15.2 | tar -x -C "$1"
    else
        tar -xf "$SRC" -C "$1" --strip-components=1
    fi
}

# build_and_test <dir> <label> -> prints the glib test summary, returns its rc
build_and_test() {
    local d="$1" label="$2" b="$1/build" rc
    cp "$TDIR/boot_emmc_hooks.c" "$d/test/boot_emmc_hooks.c"
    sed -i "s/^  'boot_raw_fallback',$/  'boot_raw_fallback',\n  'boot_emmc_hooks',/" "$d/test/meson.build"
    grep -q "'boot_emmc_hooks'" "$d/test/meson.build" || { echo "$label: cannot register the test" >&2; return 2; }
    meson setup "$b" "$d" -Dtests=true -Dservice=false -Dstreaming=false -Dnetwork=false \
        -Djson=enabled -Dgpt=disabled -Dfuzzing=false >"$W/$label-setup.log" 2>&1 \
        || { echo "$label: meson setup failed (see below)"; tail -20 "$W/$label-setup.log"; return 2; }
    ninja -C "$b" test/boot_emmc_hooks-test >"$W/$label-build.log" 2>&1 \
        || { echo "$label: build failed"; tail -20 "$W/$label-build.log"; return 2; }
    cc -shared -fPIC -o "$W/emmc_shim.so" "$TDIR/emmc_shim.c" -ldl || return 2
    mkdir -p "$W/sysfs/mmcblk0boot0" "$W/sysfs/mmcblk0boot1"
    # One process per case: a failed g_assert aborts the process. ulimit -f
    # (KiB) backstops a stand-in device growing without bound.
    rc=0; : > "$W/$label-run.log"
    for c in no_hooks pre_post_order post_fail_no_flip pre_fail_no_write guard_hooks guard_no_approval; do
        (cd "$d" && ulimit -f 65536 && env LD_PRELOAD="$W/emmc_shim.so" SHIM_LOG="$W/shim.log" \
            SHIM_EXTCSD="$W/extcsd" SHIM_SYSFS="$W/sysfs" SHIM_DEVSIZE=$((1 << 20)) TMPDIR="$W" \
            BOOT_EMMC_DEVDIR="$W/dev-$label-$c" PATH="$W/bin:$PATH" ${GUARD_HOOK:+RZB_SLOT_HOOK="$GUARD_HOOK"} \
            RZB_LIB="$W/common.sh" RZB_MMC_DEV="$W/dev-$label-$c/mmcblk0" RZB_RUN_DIR="$W/run" \
            RZB_BOOT_ID_FILE="$W/boot_id" RZB_DD_IFLAG="" \
            "$b/test/boot_emmc_hooks-test" --tap -p "/boot_emmc_hooks/$c") >>"$W/$label-run.log" 2>&1 || rc=1
        grep -q -E "^(ok|not ok) .*/boot_emmc_hooks/$c" "$W/$label-run.log" \
            || echo "not ok /boot_emmc_hooks/$c - aborted" >> "$W/$label-run.log"
    done
    echo "--- $label (RAUC v1.15.2$( [ "$label" = patched ] && echo ' + backport a75bbb2b'))"
    grep -E '^(ok|not ok)' "$W/$label-run.log" | sed 's/^/    /'
    return "$rc"
}

# The RZ/V2L guard slot hook, rendered as the guard recipe installs it, with a
# fake `mmc` reading the shim's EXT_CSD (mmc-utils' output format).
GUARD="$ROOT/meta-edge-bsp/dynamic-layers/meta-rz-bsp/recipes-ota/rzv2l-bootchain/files"
# Without the RZ/V2L guard in the tree, the guard cases report SKIP.
GUARD_HOOK=""; [ -f "$GUARD/rzv2l-bootchain-slot-hook" ] && GUARD_HOOK="$GUARD/rzv2l-bootchain-slot-hook"
mkdir -p "$W/bin" "$W/run"
[ -f "$GUARD/rzv2l-bootchain-common.sh" ] && sed -e "s|@MMC_DEV@|/dev/mmcblk0|" -e "s|@BL2_OFFSET@|0x200|" -e "s|@FIP_OFFSET@|0x20000|" \
    -e "s|@TFA_FIP_LAYOUT@|2.10:0x20000|" "$GUARD/rzv2l-bootchain-common.sh" > "$W/common.sh"
printf '#!/bin/sh\necho "Boot configuration bytes [PARTITION_CONFIG: $(cat %s/extcsd)]"\necho "Boot bus Conditions [BOOT_BUS_CONDITIONS: 0x02]"\n' "$W" > "$W/bin/mmc"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/blockdev"; chmod +x "$W/bin/mmc" "$W/bin/blockdev"
echo "c0ffee00-0000-0000-0000-000000000000" > "$W/boot_id"

extract "$W/stock"; extract "$W/patched"
(cd "$W/patched" && patch -p1 --quiet < "$PATCH") || { echo "patch does not apply to v1.15.2" >&2; exit 1; }

build_and_test "$W/stock" stock; stock_rc=$?
grep -E 'CRITICAL|refus' "$W/stock-run.log" | head -3 | sed 's/^/    stock: /'
build_and_test "$W/patched" patched; patched_rc=$?

fail=0
stock_bad=$(grep -c '^not ok' "$W/stock-run.log" 2>/dev/null || true)
grep -q '^not ok .*/pre_post_order' "$W/stock-run.log" && grep -q '^not ok .*/post_fail_no_flip' "$W/stock-run.log" \
    && { [ -z "$GUARD_HOOK" ] || grep -q '^not ok .*/guard_hooks' "$W/stock-run.log"; } \
    && echo "PASS  stock v1.15.2 fails the hooked boot-emmc cases (bug reproduced)" \
    || { echo "FAIL  stock v1.15.2 did not fail the hooked cases"; fail=1; }
grep -q '^ok .*/no_hooks' "$W/stock-run.log" \
    && echo "PASS  stock v1.15.2 passes the hook-less case (shim and fixture are sound)" \
    || { echo "FAIL  stock no_hooks case"; fail=1; }
[ "$patched_rc" -eq 0 ] && ! grep -q '^not ok' "$W/patched-run.log" \
    && { [ -z "$GUARD_HOOK" ] || ! grep -q '# SKIP' "$W/patched-run.log"; } \
    && echo "PASS  patched: all boot-emmc hook cases pass$( [ -z "$GUARD_HOOK" ] && echo ' (guard cases skipped: no RZ/V2L guard in the tree)')" \
    || { echo "FAIL  patched run (rc=$patched_rc)"; tail -15 "$W/patched-run.log"; fail=1; }
echo "stock rc=$stock_rc (not-ok cases: $stock_bad), patched rc=$patched_rc"
exit "$fail"

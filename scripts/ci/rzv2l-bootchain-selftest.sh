#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Host self-test for the RZ/V2L eMMC bootloader-slot guards
# (meta-edge-bsp/dynamic-layers/meta-rz-bsp/recipes-ota/rzv2l-bootchain/).
#
# Real parts: bundles are built, signed and read back with the build's native
# rauc (the same version the image ships), the composer runs on the build's
# BL2/FIP, the guard scripts run unmodified. Mocked parts: the eMMC (regular
# files for boot0/boot1, a fake `mmc` printing mmc-utils' EXT_CSD lines from a
# file), sysfs/device-tree, and RAUC's install sequence, which `sim_install`
# replays in the order of RAUC 1.15.2 src/update_handler.c
# (img_to_boot_emmc_handler / copy_img_to_emmc_bootpart) and src/install.c
# (pre-install handler before any slot write). Nothing here touches a device.
#
#   scripts/ci/rzv2l-bootchain-selftest.sh
#
# Needs a build that produced rauc-native, squashfs-tools-native and the
# RZ/V2L BL2/FIP (bl2_bp_mmc-*_pmic.bin, fip-*_pmic.bin). Exit 0 when every
# case matches.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/meta-edge-bsp/dynamic-layers/meta-rz-bsp/recipes-ota/rzv2l-bootchain/files"
SYS="$ROOT/build/rzv2l/tmp/sysroots-components/x86_64"
DEPLOY="${DEPLOY:-$ROOT/build/rzv2l/tmp/deploy/images/smarc-rzv2l}"
RAUC_BIN="$SYS/rauc-native/usr/bin/rauc"
LIBS=$(ls -d "$SYS"/*/usr/lib 2>/dev/null | tr '\n' ':')
[ -x "$RAUC_BIN" ] || { echo "no native rauc at $RAUC_BIN (build rauc-native)" >&2; exit 2; }
for f in "$DEPLOY/bl2_bp_mmc-smarc-rzv2l_pmic.bin" "$DEPLOY/fip-smarc-rzv2l_pmic.bin"; do
    [ -f "$f" ] || { echo "missing $f (build firmware-pack)" >&2; exit 2; }
done
for t in openssl dtc fdtget python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rauc() { env PATH="$SYS/squashfs-tools-native/usr/bin:$PATH" LD_LIBRARY_PATH="$LIBS" "$RAUC_BIN" "$@"; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

# --- throwaway signing PKI --------------------------------------------------
mkdir -p "$T/pki"
openssl req -batch -x509 -newkey rsa:2048 -nodes -keyout "$T/pki/ca.key" -out "$T/pki/ca.pem" \
    -subj "/CN=selftest-ca" -days 2 -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
openssl req -batch -newkey rsa:2048 -nodes -keyout "$T/pki/signer.key" -out "$T/pki/signer.csr" -subj "/CN=selftest-signer" 2>/dev/null
printf 'extendedKeyUsage=codeSigning,emailProtection\nkeyUsage=digitalSignature\n' > "$T/pki/ext"
openssl x509 -req -in "$T/pki/signer.csr" -CA "$T/pki/ca.pem" -CAkey "$T/pki/ca.key" -CAcreateserial \
    -out "$T/pki/signer.pem" -days 2 -extfile "$T/pki/ext" 2>/dev/null

# --- fake board ---------------------------------------------------------------
mkdir -p "$T/dev" "$T/sys/block/mmcblk0/device" "$T/dt/chosen" "$T/dt/soc/i2c@0/pmic@12" \
    "$T/run" "$T/share" "$T/boot" "$T/bin" "$T/sys/block/mmcblk0boot0" "$T/sys/block/mmcblk0boot1"
echo MMC > "$T/sys/block/mmcblk0/device/type"
: > "$T/dev/mmcblk0"
for p in 0 1; do
    head -c $((4 << 20)) /dev/zero > "$T/dev/mmcblk0boot$p"
    echo $(( (4 << 20) / 512 )) > "$T/sys/block/mmcblk0boot$p/size"
    echo 1 > "$T/sys/block/mmcblk0boot$p/force_ro"
done
printf 'emmc\0' > "$T/dt/chosen/edge,boot-source"
printf 'renesas,raa215300\0' > "$T/dt/soc/i2c@0/pmic@12/compatible"
echo "11111111-2222-3333-4444-555555555555" > "$T/boot_id"
echo 0x08 > "$T/extcsd_pc"; echo 0x02 > "$T/extcsd_bb"
cat > "$T/bin/mmc" <<EOF
#!/bin/sh
[ "\$1 \$2" = "extcsd read" ] || exit 1
echo "Boot configuration bytes [PARTITION_CONFIG: \$(cat $T/extcsd_pc)]"
echo "Boot bus Conditions [BOOT_BUS_CONDITIONS: \$(cat $T/extcsd_bb)]"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/blockdev"
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$T/bin/id"
cat > "$T/bin/rauc" <<EOF
#!/bin/sh
[ "\$1" = info ] || exit 1
shift
exec env PATH="$SYS/squashfs-tools-native/usr/bin:\$PATH" LD_LIBRARY_PATH="$LIBS" "$RAUC_BIN" info --keyring="$T/pki/ca.pem" "\$@"
EOF
chmod +x "$T/bin/"*
cp "$SRC/rzv2l-bootchain-bundle-hook.sh" "$T/share/bundle-hook.sh"
sed -e "s|@MMC_DEV@|/dev/mmcblk0|" -e "s|@BL2_OFFSET@|0x200|" -e "s|@FIP_OFFSET@|0x20000|" \
    -e "s|@TFA_FIP_LAYOUT@|2.10:0x20000|" "$SRC/rzv2l-bootchain-common.sh" > "$T/common.sh"

export PATH="$T/bin:$PATH" RZB_LIB="$T/common.sh" RZB_MMC_DEV="$T/dev/mmcblk0" RZB_SYSFS="$T/sys" \
    RZB_DT="$T/dt" RZB_RUN_DIR="$T/run" RZB_SHARE_DIR="$T/share" RZB_BOOT_DIR="$T/boot" \
    RZB_BOOT_ID_FILE="$T/boot_id" RZB_DD_IFLAG=""

# Slot FITs: conf-A/conf-B signed by key-name-hint $1 (dtc-built stand-ins; only
# the signer hint is read by the anchor guard).
mkfits() {
    for s in A B; do
        printf '/dts-v1/; / { configurations { conf-%s { signature-1 { key-name-hint = "%s"; }; }; }; };' "$s" "$1" \
            | dtc -q -O dtb -o "$T/boot/fitImage-$s" -
    done
}

# --- bundles ----------------------------------------------------------------
COMPOSE="$SRC/rzv2l-bootchain-compose.py"
BL2="$DEPLOY/bl2_bp_mmc-smarc-rzv2l_pmic.bin"; FIP="$DEPLOY/fip-smarc-rzv2l_pmic.bin"
python3 "$COMPOSE" --bl2 "$BL2" --fip "$FIP" --out "$T/good.img" --bl2-offset 0x200 --fip-offset 0x20000 \
    --bootpart-size 0x400000 --tfa-pin 2.10 --layout "2.10:0x20000" --anchor-out "$T/anchor.dtb" > "$T/good.meta" \
    || { echo "composer failed on the build's BL2/FIP" >&2; exit 2; }

# mkbundle <name> <image> <meta-file> [hooks] [variant] [pin] [hookfile] [extra-manifest]
mkbundle() {
    local n="$1" img="$2" meta="$3" hooks="${4:-pre-install;post-install}" variant="${5:-pmic}" pin="${6:-2.10}" \
        hook="${7:-$SRC/rzv2l-bootchain-bundle-hook.sh}" extra="${8:-}" c="$T/content-$1"
    mkdir -p "$c"
    cp "$img" "$c/bootchain.img"; cp "$hook" "$c/hook.sh"; chmod +x "$c/hook.sh"
    {
        printf '[update]\ncompatible=edge-ai-smarc-rzv2l\nversion=0.1.0\nbuild=%s\n\n' "$n"
        printf '[bundle]\nformat=verity\n\n'
        printf '[hooks]\nfilename=hook.sh\n'
        [ -n "$extra" ] && printf '%b' "$extra"
        printf '\n[image.bootloader]\nfilename=bootchain.img\nhooks=%s\n\n' "$hooks"
        printf '[meta.edge]\nbootchain-format=rzv2l-emmc-bootpart-v1\nvariant=%s\ntfa-pin=%s\nbuild-id=%s\n' "$variant" "$pin" "$n"
        cat "$meta"
    } > "$c/manifest.raucm"
    rauc bundle --cert="$T/pki/signer.pem" --key="$T/pki/signer.key" --keyring="$T/pki/ca.pem" \
        "$c" "$T/$n.raucb" >/dev/null 2>&1 || { echo "rauc bundle failed for $n" >&2; exit 2; }
    rauc extract --keyring="$T/pki/ca.pem" "$T/$n.raucb" "$T/mnt-$n" >/dev/null 2>&1 \
        || { echo "rauc extract failed for $n" >&2; exit 2; }
    rauc info --keyring="$T/pki/ca.pem" --output-format=shell "$T/$n.raucb" 2>/dev/null > "$T/$n.info"
}

# RAUC pre-install handler environment for bundle <name>, as RAUC 1.15.2
# install.c builds it: RAUC_TARGET_SLOTS lists one inactive slot per root class
# of system.conf whatever the bundle carries (slot 2 = rootfs.1, 3 =
# bootloader.0); RAUC_IMAGE_*_<n> only for slots the manifest has an image for.
# <system> "noblslot" = a system.conf without the bootloader slot.
handler_env() {
    local n="$1" system="${2:-}" k v cls i
    HENV=(RAUC_BUNDLE_MOUNT_POINT="$T/mnt-$n" RAUC_TRANSACTION_ID="tx-$n-$RANDOM" RAUC_SLOTS="1 2 3"
          RAUC_SLOT_CLASS_1=rootfs RAUC_SLOT_CLASS_2=rootfs RAUC_SLOT_CLASS_3=bootloader RAUC_TARGET_SLOTS="2 3")
    [ "$system" = noblslot ] && HENV=(RAUC_BUNDLE_MOUNT_POINT="$T/mnt-$n" RAUC_TRANSACTION_ID="tx-$n-$RANDOM"
          RAUC_SLOTS="1 2" RAUC_SLOT_CLASS_1=rootfs RAUC_SLOT_CLASS_2=rootfs RAUC_TARGET_SLOTS="2")
    for i in 0 1 2; do
        cls="$(info "$n" "RAUC_IMAGE_CLASS_$i")"
        case "$cls" in
            rootfs) HENV+=(RAUC_IMAGE_CLASS_2=rootfs RAUC_IMAGE_NAME_2="$(info "$n" "RAUC_IMAGE_NAME_$i")" RAUC_IMAGE_DIGEST_2="$(info "$n" "RAUC_IMAGE_DIGEST_$i")") ;;
            bootloader) [ "$system" = noblslot ] || HENV+=(RAUC_IMAGE_CLASS_3=bootloader RAUC_IMAGE_NAME_3="$(info "$n" "RAUC_IMAGE_NAME_$i")" RAUC_IMAGE_DIGEST_3="$(info "$n" "RAUC_IMAGE_DIGEST_$i")") ;;
        esac
    done
    while IFS= read -r line; do
        case "$line" in RAUC_META_*=*) k="${line%%=*}"; v="${line#*=}"; v="${v#\'}"; v="${v%\'}"; HENV+=("$k=$v") ;; esac
    done < "$T/$n.info"
}
info() { local v; v="$(grep "^$2=" "$T/$1.info" | head -1)"; v="${v#*=}"; v="${v#\'}"; printf '%s' "${v%\'}"; }

handler() { env "${HENV[@]}" bash "$SRC/rzv2l-bootchain-preinstall" 2>&1; }
authorize() { bash "$SRC/rzv2l-bootchain-authorize" "$@" 2>&1; }
hashes() { sha256sum "$T/dev/mmcblk0boot0" "$T/dev/mmcblk0boot1" "$T/extcsd_pc" | awk '{print $1}' | tr '\n' ' '; }

# expect_reject <label> <pattern> <command...>
expect_reject() {
    local label="$1" pat="$2" out rc; shift 2
    out="$("$@")"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "$pat"; then ok "$label"
    else bad "$label" "rc=$rc out: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
}
expect_accept() {
    local label="$1" out rc; shift
    out="$("$@")"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "$label"; else bad "$label" "rc=$rc out: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
}

# sim_install <bundle> [corrupt]: RAUC 1.15.2 boot-emmc order. Handler, then
# force_ro off, slot-pre-install, clear, write, [corrupt one byte],
# slot-post-install, force_ro on, flip EXT_CSD, re-read. Returns non-zero at the
# first failing step; nothing after it runs.
sim_install() {
    local n="$1" corrupt="${2:-}" pc en act tgt dev
    handler_env "$n"; handler > "$T/last-handler" || return 10
    pc=$(( $(cat "$T/extcsd_pc") )); en=$(( (pc >> 3) & 7 ))
    case "$en" in 1) act=0 ;; 2) act=1 ;; *) act=1 ;; esac
    tgt=$(( 1 - act )); dev="$T/dev/mmcblk0boot$tgt"
    echo 0 > "$T/sys/block/mmcblk0boot$tgt/force_ro"
    local SENV=(RAUC_SLOT_CLASS=bootloader RAUC_SLOT_DEVICE="$T/dev/mmcblk0" RAUC_BOOT_PARTITION_ACTIVATING="$tgt"
                RAUC_IMAGE_DIGEST="$(info "$n" RAUC_IMAGE_DIGEST_0)" RAUC_IMAGE_SIZE="$(info "$n" RAUC_IMAGE_SIZE_0)")
    env "${SENV[@]}" bash "$T/mnt-$n/hook.sh" slot-pre-install >/dev/null 2>&1 || { echo 1 > "$T/sys/block/mmcblk0boot$tgt/force_ro"; return 11; }
    head -c $((4 << 20)) /dev/zero > "$dev"
    dd if="$T/mnt-$n/bootchain.img" of="$dev" conv=notrunc status=none
    [ -n "$corrupt" ] && printf '\xff' | dd of="$dev" bs=1 seek=$((0x20010)) conv=notrunc status=none
    env "${SENV[@]}" bash "$T/mnt-$n/hook.sh" slot-post-install >/dev/null 2>&1 || { echo 1 > "$T/sys/block/mmcblk0boot$tgt/force_ro"; return 12; }
    echo 1 > "$T/sys/block/mmcblk0boot$tgt/force_ro"
    printf '%#04x\n' $(( (pc & 0x40) | (tgt == 0 ? 0x08 : 0x10) )) > "$T/extcsd_pc"
    return 0
}
reset_board() {
    for p in 0 1; do head -c $((4 << 20)) /dev/zero > "$T/dev/mmcblk0boot$p"; done
    dd if="$T/good.img" of="$T/dev/mmcblk0boot0" conv=notrunc status=none
    echo 0x08 > "$T/extcsd_pc"; echo 0x02 > "$T/extcsd_bb"; printf 'emmc\0' > "$T/dt/chosen/edge,boot-source"
    rm -f "$T/run/authorization" "$T/run/approved"; mkfits edge-fit-dev
}
# Write a matching authorization for bundle <name> directly, bypassing the
# authorize tool's own checks, so the handler's checks are what is exercised.
grant() {
    { echo "format=rzv2l-emmc-bootpart-v1"; echo "image_digest=$(info "$1" RAUC_IMAGE_DIGEST_0)"; echo "build_id=$1"
      echo "boot_id=$(cat "$T/boot_id")"; echo "expires=$(( $(date +%s) + 300 ))"; } > "$T/run/authorization"
}
# The hook stub execs /usr/lib/rzv2l-bootchain/slot-hook; point it at the source.
fix_stub() { sed -i "s|/usr/lib/rzv2l-bootchain/slot-hook|$SRC/rzv2l-bootchain-slot-hook|" "$T/mnt-$1/hook.sh"; }

# --- build the bundle set ---------------------------------------------------
mkbundle good  "$T/good.img" "$T/good.meta"
mkbundle good2 "$T/good.img" "$T/good.meta"
mkbundle nopost "$T/good.img" "$T/good.meta" "pre-install"
# rauc refuses install combined with pre/post-install, so the bypass is install alone.
mkbundle inshook "$T/good.img" "$T/good.meta" "install"
printf '#!/bin/sh\necho tampered\nexit 0\n' > "$T/evil-hook.sh"
mkbundle badhook "$T/good.img" "$T/good.meta" "pre-install;post-install" pmic 2.10 "$T/evil-hook.sh"
mkbundle bhook "$T/good.img" "$T/good.meta" "pre-install;post-install" pmic 2.10 "" 'hooks=install-check\n'
mkbundle nonpmic "$T/good.img" "$T/good.meta" "pre-install;post-install" non-pmic
mkbundle pin "$T/good.img" "$T/good.meta" "pre-install;post-install" pmic 2.12
python3 - "$T/good.img" "$T/nohdr.img" <<'EOF'
import sys
b = bytearray(open(sys.argv[1], "rb").read()); b[0x200 + 0x1FE:0x200 + 0x200] = b"\0\0"
open(sys.argv[2], "wb").write(b)
EOF
python3 - "$T/good.meta" "$T/nohdr.img" "$T/nohdr.meta" <<'EOF'
import hashlib, sys
meta = dict(l.strip().split("=", 1) for l in open(sys.argv[1]) if "=" in l)
img = open(sys.argv[2], "rb").read()
meta["bl2-sha256"] = hashlib.sha256(img[0x200:0x200 + int(meta["bl2-size"])]).hexdigest()
open(sys.argv[3], "w").write("".join("%s=%s\n" % kv for kv in meta.items()))
EOF
mkbundle nohdr "$T/nohdr.img" "$T/nohdr.meta"
sed 's/^bl2-sha256=.*/bl2-sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$T/good.meta" > "$T/badsha.meta"
mkbundle badsha "$T/good.img" "$T/badsha.meta"
# A plain rootfs-only bundle (what the unattended path installs).
mkdir -p "$T/content-rootfs"; head -c 65536 /dev/urandom > "$T/content-rootfs/rootfs.img"
printf '[update]\ncompatible=edge-ai-smarc-rzv2l\nversion=0.1.0\n\n[bundle]\nformat=verity\n\n[image.rootfs]\nfilename=rootfs.img\n' > "$T/content-rootfs/manifest.raucm"
rauc bundle --cert="$T/pki/signer.pem" --key="$T/pki/signer.key" --keyring="$T/pki/ca.pem" "$T/content-rootfs" "$T/rootfs.raucb" >/dev/null 2>&1 \
    && rauc extract --keyring="$T/pki/ca.pem" "$T/rootfs.raucb" "$T/mnt-rootfs" >/dev/null 2>&1 \
    && rauc info --keyring="$T/pki/ca.pem" --output-format=shell "$T/rootfs.raucb" 2>/dev/null > "$T/rootfs.info" \
    || { echo "rootfs bundle build failed" >&2; exit 2; }
# A real two-image bundle: rootfs + bootloader.
mkdir -p "$T/content-mixed"; cp "$T/content-rootfs/rootfs.img" "$T/good.img" "$T/content-mixed/"
cp "$SRC/rzv2l-bootchain-bundle-hook.sh" "$T/content-mixed/hook.sh"; chmod +x "$T/content-mixed/hook.sh"
{ printf '[update]\ncompatible=edge-ai-smarc-rzv2l\nversion=0.1.0\nbuild=mixed\n\n[bundle]\nformat=verity\n\n[hooks]\nfilename=hook.sh\n\n'
  printf '[image.rootfs]\nfilename=rootfs.img\n\n[image.bootloader]\nfilename=good.img\nhooks=pre-install;post-install\n\n'
  printf '[meta.edge]\nbootchain-format=rzv2l-emmc-bootpart-v1\nvariant=pmic\ntfa-pin=2.10\nbuild-id=mixed\n'; cat "$T/good.meta"; } > "$T/content-mixed/manifest.raucm"
rauc bundle --cert="$T/pki/signer.pem" --key="$T/pki/signer.key" --keyring="$T/pki/ca.pem" "$T/content-mixed" "$T/mixed.raucb" >/dev/null 2>&1 \
    && rauc extract --keyring="$T/pki/ca.pem" "$T/mixed.raucb" "$T/mnt-mixed" >/dev/null 2>&1 \
    && rauc info --keyring="$T/pki/ca.pem" --output-format=shell "$T/mixed.raucb" 2>/dev/null > "$T/mixed.info" \
    || { echo "mixed bundle build failed" >&2; exit 2; }
# BL2 truncated to its boot-parameter block; the header still declares the full body.
python3 - "$T/good.img" "$T/good.meta" "$T/trunc.img" "$T/trunc.meta" <<'PY'
import hashlib, sys
img = bytearray(open(sys.argv[1], "rb").read())
meta = dict(l.strip().split("=", 1) for l in open(sys.argv[2]) if "=" in l)
n = int(meta["bl2-size"]); img[0x200 + 0x200:0x200 + n] = bytes(n - 0x200)
meta["bl2-size"] = "512"; meta["bl2-sha256"] = hashlib.sha256(img[0x200:0x400]).hexdigest()
open(sys.argv[3], "wb").write(img); open(sys.argv[4], "w").write("".join("%s=%s\n" % kv for kv in meta.items()))
PY
mkbundle trunc "$T/trunc.img" "$T/trunc.meta"
for n in mixed trunc good good2 nopost inshook badhook bhook nonpmic pin nohdr badsha; do fix_stub "$n"; done
cmp -s "$T/mnt-badhook/hook.sh" "$T/share/bundle-hook.sh" && { echo "internal: badhook stub not distinct" >&2; exit 2; }
# The reference copy must match the stub as the handler sees it after fix_stub.
fix_ref() { sed "s|/usr/lib/rzv2l-bootchain/slot-hook|$SRC/rzv2l-bootchain-slot-hook|" "$SRC/rzv2l-bootchain-bundle-hook.sh" > "$T/share/bundle-hook.sh"; }
fix_ref

echo "== real rauc: manifests as built"
[ "$(info good RAUC_IMAGE_HOOKS_0)" = "pre-install post-install" ] && ok "rauc info: good bundle declares pre+post-install hooks" || bad "rauc info hooks" "$(info good RAUC_IMAGE_HOOKS_0)"
grep -q '^hooks=pre-install;post-install' "$T/mnt-good/manifest.raucm" && ok "payload manifest.raucm carries the same image hooks" || bad "payload manifest hooks"
[ "$(info nopost RAUC_IMAGE_HOOKS_0)" = "pre-install" ] && ok "rauc info: nopost bundle lacks post-install" || bad "nopost hooks"

echo "== pass-through: bundles without the bootloader class"
reset_board
authorize "$T/good.raucb" >/dev/null; before="$(ls -R "$T/run")"
handler_env rootfs
expect_accept "rootfs-only bundle passes the handler (targets list rootfs + bootloader, as RAUC sets it)" handler
[ "$(ls -R "$T/run")" = "$before" ] && [ -e "$T/run/authorization" ] && ok "rootfs-only install leaves a pending bootchain authorization untouched" || bad "rootfs-only state" "$(ls -R "$T/run")"
handler_env good noblslot
expect_reject "bootloader image on a system without the bootloader slot" "targets no bootloader slot" handler

echo "== authorization"
reset_board; handler_env good
expect_reject "bootloader bundle without authorization" "no operator authorization" handler
reset_board; grant mixed; handler_env mixed
expect_reject "mixed rootfs + bootloader bundle (real two-image manifest)" "bootchain bundles must carry the bootchain only" handler
expect_reject "authorize refuses the mixed bundle" "carries 2 images" authorize "$T/mixed.raucb"
reset_board; authorize "$T/good2.raucb" >/dev/null; handler_env good
expect_reject "authorization for another bundle (wrong build/digest)" "authorization is for" handler
[ ! -e "$T/run/authorization" ] && ok "wrong-bundle attempt consumed the authorization" || bad "wrong-bundle consumption"
handler_env good
expect_reject "second attempt after a consumed authorization" "no operator authorization" handler
reset_board; authorize --ttl 1 "$T/good.raucb" >/dev/null; sleep 2; handler_env good
expect_reject "expired authorization" "expired" handler
reset_board; authorize "$T/good.raucb" >/dev/null; echo "99999999-0000-0000-0000-000000000000" > "$T/boot_id"; handler_env good
expect_reject "authorization from another boot" "another boot" handler
echo "11111111-2222-3333-4444-555555555555" > "$T/boot_id"
expect_reject "authorize refuses a bundle without post-install" "no slot post-install hook" authorize "$T/nopost.raucb"
expect_reject "authorize refuses an install-only hook (no read-back)" "no slot pre-install hook" authorize "$T/inshook.raucb"
expect_reject "authorize refuses bundle hooks" "bundle hooks" authorize "$T/bhook.raucb"

echo "== bundle content (authorization valid; handler must still refuse)"
for c in "nopost|no slot post-install hook" "inshook|no slot pre-install hook" "badhook|differs from" "bhook|bundle hooks" \
         "nonpmic|this board is pmic" "pin|not in the known layouts" "nohdr|AA55" "badsha|BL2 region hash" "trunc|does not match the"; do
    n="${c%%|*}"; pat="${c#*|}"
    reset_board
    grant "$n"
    handler_env "$n"
    expect_reject "handler refuses '$n'" "$pat" handler
done

echo "== board state"
for c in "boot-source|esd|not emmc" "extcsd-0|0x00|not boot0/boot1" "extcsd-uda|0x38|not boot0/boot1" "boot-ack|0x48|BOOT_ACK" "bus|0x01|8-bit"; do
    IFS='|' read -r label val pat <<< "$c"
    reset_board; authorize "$T/good.raucb" >/dev/null
    case "$label" in boot-source) printf 'esd\0' > "$T/dt/chosen/edge,boot-source" ;; bus) echo "$val" > "$T/extcsd_bb" ;; *) echo "$val" > "$T/extcsd_pc" ;; esac
    handler_env good
    expect_reject "board: $label" "$pat" handler
done
reset_board; authorize "$T/good.raucb" >/dev/null; mkfits other-key; handler_env good
expect_reject "anchor: slot FIT signed by a key outside the current anchor" "not a key of the current anchor" handler

echo "== sequencing (mocked RAUC boot-emmc order)"
reset_board; grant badhook; h0="$(hashes)"
sim_install badhook; rc=$?
[ "$rc" -eq 10 ] && grep -q "differs from" "$T/last-handler" && [ "$(hashes)" = "$h0" ] && ok "handler rejection: boot0, boot1 and EXT_CSD unchanged" || bad "handler rejection sequencing" "rc=$rc"
reset_board; h0="$(hashes)"
SENV=(RAUC_SLOT_CLASS=bootloader RAUC_SLOT_DEVICE="$T/dev/mmcblk0" RAUC_BOOT_PARTITION_ACTIVATING=1
      RAUC_IMAGE_DIGEST="$(info good RAUC_IMAGE_DIGEST_0)" RAUC_IMAGE_SIZE="$(info good RAUC_IMAGE_SIZE_0)")
out="$(env "${SENV[@]}" bash "$T/mnt-good/hook.sh" slot-pre-install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no approval" && [ "$(hashes)" = "$h0" ] \
    && ok "slot-pre-install without the handler's approval fails before any write" || bad "pre-install without approval" "rc=$rc $out"
reset_board; authorize "$T/good.raucb" >/dev/null
sim_install good corrupt; rc=$?
[ "$rc" -eq 12 ] && [ "$(cat "$T/extcsd_pc")" = 0x08 ] && ok "read-back mismatch: post-install fails, EXT_CSD not flipped (boot0 stays)" || bad "read-back mismatch" "rc=$rc pc=$(cat "$T/extcsd_pc")"
reset_board; authorize "$T/good.raucb" >/dev/null
sim_install good; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$T/extcsd_pc")" = 0x10 ] \
    && cmp -s <(head -c "$(stat -c%s "$T/good.img")" "$T/dev/mmcblk0boot1") "$T/good.img" \
    && ok "good bundle: boot1 written + verified, EXT_CSD -> boot1" || bad "good install" "rc=$rc pc=$(cat "$T/extcsd_pc")"
authorize "$T/good.raucb" >/dev/null
sim_install good; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$T/extcsd_pc")" = 0x08 ] && ok "second install switches back: boot0 written, EXT_CSD -> boot0" || bad "switch back" "rc=$rc pc=$(cat "$T/extcsd_pc")"
sim_install good; rc=$?
[ "$rc" -eq 10 ] && grep -q "no operator authorization" "$T/last-handler" && [ "$(cat "$T/extcsd_pc")" = 0x08 ] && ok "no re-use: a third install without a new authorization is refused" || bad "re-use" "rc=$rc"

echo "== composer (build-time checks)"
python3 - "$BL2" "$T/bl2-nohdr.bin" <<'EOF'
import sys
b = bytearray(open(sys.argv[1], "rb").read()); b[0x1FE:0x200] = b"\0\0"; open(sys.argv[2], "wb").write(b)
EOF
# shellcheck disable=SC2069  # stderr captured, stdout (the meta) dropped
comp() { python3 "$COMPOSE" --bl2 "$1" --fip "$2" --out "$T/c.img" --bl2-offset 0x200 --fip-offset "${3:-0x20000}" \
    --bootpart-size "${4:-0x400000}" --tfa-pin "${5:-2.10}" --layout "2.10:0x20000" --anchor-out "$T/c.dtb" 2>&1 >/dev/null; }
expect_reject "composer: BL2 without AA55" "AA55" comp "$T/bl2-nohdr.bin" "$FIP"
expect_reject "composer: FIP without ToC" "ToC" comp "$BL2" "$BL2"
expect_reject "composer: TF-A pin offset mismatch" "reads the FIP at" comp "$BL2" "$FIP" 0x30000
expect_reject "composer: unknown TF-A pin" "not in the layout table" comp "$BL2" "$FIP" 0x20000 0x400000 2.12
expect_reject "composer: image larger than the boot partition" "exceeds the boot partition" comp "$BL2" "$FIP" 0x20000 0x100000
head -c 512 "$BL2" > "$T/bl2-hdronly.bin"
expect_reject "composer: BL2 truncated to its boot parameters (size word 59684)" "does not match the" comp "$T/bl2-hdronly.bin" "$FIP"
head -c $(( $(stat -c%s "$BL2") - 4 )) "$BL2" > "$T/bl2-short.bin"
expect_reject "composer: BL2 body 4 bytes short of its size word" "does not match the" comp "$T/bl2-short.bin" "$FIP"

echo "== anchor guard unit cases (synthetic DTBs)"
# key <node-name> <modulus words> [required]
mkdtb() {
    local out="$1"; shift
    { printf '/dts-v1/; / { signature {'
      while [ $# -gt 0 ]; do printf ' key-%s { rsa,modulus = <%s>; rsa,exponent = <0 65537>; %s };' "$1" "$2" "${3:+required = \"conf\";}"; shift 3; done
      printf ' }; };'; } | dtc -q -O dtb -o "$out" -
}
mkdtb "$T/a-cur.dtb" k1 "0x11 0x22" r
mkdtb "$T/a-same.dtb" k1 "0x11 0x22" r
mkdtb "$T/a-diff.dtb" k1 "0x99 0x88" r
mkdtb "$T/a-k2.dtb" k2 "0x33 0x44" r
anchor() { ( set -euo pipefail; IFS=$'\n\t'; . "$T/common.sh"; rzb_check_anchor "$1" "$2" ) 2>&1; }
mkfits k1
expect_accept "anchor: same key (modulus) in current and candidate" anchor "$T/a-same.dtb" "$T/a-cur.dtb"
expect_reject "anchor: same name, different modulus" "does not trust key 'k1'" anchor "$T/a-diff.dtb" "$T/a-cur.dtb"
expect_reject "anchor: signer absent from the current anchor (no name-only fallback)" "not a key of the current anchor" anchor "$T/a-diff.dtb" "$T/a-k2.dtb"
expect_reject "anchor: current anchor unavailable" "no current anchor" anchor "$T/a-diff.dtb" ""
reset_board; grant good; head -c $((4 << 20)) /dev/zero > "$T/dev/mmcblk0boot0"; handler_env good
expect_reject "handler: active partition holds no anchor" "no U-Boot DTB with FIT keys in the active" handler

echo
echo "TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

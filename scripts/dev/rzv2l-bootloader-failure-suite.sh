#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# On-target failure suite for rzv2l-bootloader-update (RZ/V2L only).
#
# Every case feeds the updater a condition it must refuse (corrupt artifact,
# wrong manifest hash, wrong mtd label, wrong PMIC variant, image too large,
# bad QSPI FIP address, wrong SD/eMMC medium, not root, operator "no", bad,
# corrupt, half-present or redirected restore run)
# and passes only when the updater exits non-zero with the expected message
# AND the bootchain storage is byte-identical afterwards. The storage
# invariant is the SHA-256 of /dev/mtd0, /dev/mtd1, the first 4 MiB of the MMC
# user area (eSD BL2/FIP + U-Boot env) and the eMMC boot0 partition when present.
# Corrupted inputs are copies under a work directory; the installed artifacts
# and backups are not modified.
#
# Run on the board as a user with sudo (one case checks the non-root refusal):
#   ssh devel@<board> 'bash -s' < scripts/dev/rzv2l-bootloader-failure-suite.sh
#   ssh devel@<board> 'bash -s -- --restore-run <run-id>' < scripts/dev/rzv2l-bootloader-failure-suite.sh
#
# Options:
#   --tool <path>         updater (default /usr/sbin/rzv2l-bootloader-update)
#   --pkg <dir>           staged artifacts + manifest.tsv (default /usr/share/rzv2l-boot)
#   --variant <v>         the board's real variant, pmic|non-pmic (default pmic)
#   --restore-run <id>    an existing backup run; enables the restore-path cases
#
# Exit status: 0 when every case passed and the invariant held, 1 otherwise.

set -u

TOOL=/usr/sbin/rzv2l-bootloader-update
PKG=/usr/share/rzv2l-boot
VARIANT=pmic
RUN=""
MMC=/dev/mmcblk0
BK=/data/rzv2l-boot/backup
WORK=/tmp/rzv2l-bl-suite

while [ $# -gt 0 ]; do
    case "$1" in
        --tool)        TOOL=$2; shift 2 ;;
        --pkg)         PKG=$2; shift 2 ;;
        --variant)     VARIANT=$2; shift 2 ;;
        --restore-run) RUN=$2; shift 2 ;;
        -h|--help)     sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *)             echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$VARIANT" in pmic) WRONG=non-pmic ;; non-pmic) WRONG=pmic ;; *) echo "bad --variant" >&2; exit 2 ;; esac
[ "$(id -u)" -ne 0 ] || { echo "run as a non-root user with sudo (case F6 checks the root guard)" >&2; exit 2; }
sudo -n true 2>/dev/null || { echo "passwordless sudo required" >&2; exit 2; }
[ -f "$TOOL" ] && [ -f "$PKG/manifest.tsv" ] || { echo "missing $TOOL or $PKG/manifest.tsv" >&2; exit 2; }

HAVE_BOOT0=0; [ -e "${MMC}boot0" ] && HAVE_BOOT0=1

inv() {
    {
        sudo sha256sum /dev/mtd0 /dev/mtd1
        sudo head -c 4194304 "$MMC" | sha256sum
        [ "$HAVE_BOOT0" -eq 1 ] && sudo sha256sum "${MMC}boot0"
    } | cut -d' ' -f1 | tr '\n' ' '
}

# Flip bit 0 of the byte at offset $2 in file $1.
flip() {
    local b
    b=$(od -An -tu1 -j"$2" -N1 "$1" | tr -d ' ')
    # shellcheck disable=SC2059
    printf "\\$(printf '%03o' $((b ^ 1)))" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}

# Artifact file for a manifest mode (column 4) and the chosen variant.
artifact() { awk -F'\t' -v m="$1" -v v="$VARIANT" -v p="$2" '$4==m && $7==v && index($1,p)==1 {print $1; exit}' "$PKG/manifest.tsv"; }

# Fresh writable copy of the package as case $1.
mk() { rm -rf "${WORK:?}/$1"; mkdir -p "$WORK"; cp -a "$PKG" "$WORK/$1"; chmod -R u+w "$WORK/$1"; }

pass=0 fail=0 skip=0
I0=$(inv)
echo "updater   $TOOL (sha256 $(sha256sum "$TOOL" | cut -c1-16)…)"
echo "artifacts $PKG, board variant $VARIANT"
echo "storage   $I0"
echo "          (sha256 of mtd0, mtd1, MMC first 4 MiB$([ "$HAVE_BOOT0" -eq 1 ] && echo ', eMMC boot0'); must not change)"

section() { printf '\n== %s\n' "$1"; }

# t <id> <what the case does> <expected refusal text> <command...>
# PASS = non-zero exit + expected refusal text + storage unchanged. The
# updater's own refusal line is printed under every case.
t() {
    local id=$1 what=$2 want=$3 out rc why="" refusal
    shift 3
    out=$("$@" 2>&1); rc=$?
    refusal=$(printf '%s\n' "$out" | sed -n 's/^\[rzv2l-bootloader-update\]\[ERROR\] //p' | tail -1)
    [ "$rc" -ne 0 ] || why="exited 0 (not refused)"
    printf '%s\n' "$out" | grep -F -- "$want" >/dev/null || why="${why:+$why; }expected \"$want\""
    [ "$(inv)" = "$I0" ] || why="${why:+$why; }STORAGE CHANGED"
    if [ -z "$why" ]; then
        printf 'PASS %-4s %s\n       refused: %s\n' "$id" "$what" "$refusal"
        pass=$((pass + 1))
    else
        printf 'FAIL %-4s %s\n       %s\n' "$id" "$what" "$why"
        printf '%s\n' "$out" | tail -3 | sed 's/^/       | /'
        fail=$((fail + 1))
    fi
}
s() { printf 'SKIP %-4s %s\n' "$1" "$2"; skip=$((skip + 1)); }

BL2_SPI=$(artifact qspi bl2)
BL2_ESD=$(artifact esd bl2)
FIP=$(artifact qspi fip)

section "QSPI write path (mtd0 = BL2, mtd1 = FIP)"
mk f1; flip "$WORK/f1/$BL2_SPI" 100
t F1 "corrupt QSPI BL2 artifact (one bit flipped)" "artifact hash != manifest" sudo env ROOT_DIR="$WORK/f1" bash "$TOOL" --mode qspi --variant "$VARIANT" --yes

mk f2; awk -F'\t' -v OFS='\t' -v f="$FIP" '$1==f{$2="0000000000000000000000000000000000000000000000000000000000000000"}1' \
    "$PKG/manifest.tsv" > "$WORK/f2/manifest.tsv"
t F2 "manifest lists a wrong FIP hash" "artifact hash != manifest" sudo env ROOT_DIR="$WORK/f2" bash "$TOOL" --mode qspi --variant "$VARIANT" --yes

t F3 "QSPI bl2 partition label does not match" "mtd layout guard" sudo env ROOT_DIR="$PKG" MTD_BL2_LABEL=notbl2 bash "$TOOL" --mode qspi --variant "$VARIANT" --yes
t F4 "--variant does not match the board PMIC" "variant guard" sudo env ROOT_DIR="$PKG" bash "$TOOL" --mode qspi --variant "$WRONG" --yes

mk f5; big=$(( $(cat /sys/class/mtd/mtd0/size) + 4096 ))
head -c "$big" /dev/urandom > "$WORK/f5/$BL2_SPI"
h=$(sha256sum "$WORK/f5/$BL2_SPI" | cut -d' ' -f1)
awk -F'\t' -v OFS='\t' -v f="$BL2_SPI" -v h="$h" -v n="$big" '$1==f{$2=h;$3=n}1' "$PKG/manifest.tsv" > "$WORK/f5/manifest.tsv"
t F5 "BL2 image larger than the bl2 partition" "would overflow" sudo env ROOT_DIR="$WORK/f5" bash "$TOOL" --mode qspi --variant "$VARIANT" --yes

t F6 "run without root" "must run as root" env ROOT_DIR="$PKG" bash "$TOOL" --mode qspi --variant "$VARIANT" --yes
t F7 "operator answers 'n' at the prompt" "aborted by operator" sh -c "echo n | sudo env ROOT_DIR='$PKG' bash '$TOOL' --mode qspi --variant $VARIANT"
t E2 "QSPI FIP address below the fip partition" "is below" sudo env ROOT_DIR="$PKG" QSPI_FIP_ADDR=0x10000 bash "$TOOL" --mode qspi --variant "$VARIANT" --yes
t E3 "QSPI FIP address not erase-aligned" "not erase-aligned" sudo env ROOT_DIR="$PKG" QSPI_FIP_ADDR=0x20100 bash "$TOOL" --mode qspi --variant "$VARIANT" --yes

section "eSD write path (SD raw area: BL2 @ 0x200, FIP @ 0x20000)"
mk s1; flip "$WORK/s1/$BL2_ESD" 100
t S1 "corrupt eSD BL2 artifact (one bit flipped)" "artifact hash != manifest" sudo env ROOT_DIR="$WORK/s1" bash "$TOOL" --mode esd --variant "$VARIANT" --yes
t S2 "--variant does not match the board PMIC" "variant guard" sudo env ROOT_DIR="$PKG" bash "$TOOL" --mode esd --variant "$WRONG" --yes
# /dev/nbd0 is an idle block device that is not an SD card (no mmc type).
if [ -b /dev/nbd0 ]; then
    t S3 "--mode esd against a device that is not an SD card" "medium guard" sudo env ROOT_DIR="$PKG" MMC_DEV=/dev/nbd0 bash "$TOOL" --mode esd --variant "$VARIANT" --yes
else
    s S3 "no /dev/nbd0 to stand in for a non-SD device"
fi

section "eMMC write path (boot0: BL2 @ 0x200, FIP @ 0x20000)"
if [ "$HAVE_BOOT0" -eq 1 ]; then
    mk m1; flip "$WORK/m1/$FIP" 9
    t M1 "corrupt FIP artifact (one bit flipped)" "artifact hash != manifest" sudo env ROOT_DIR="$WORK/m1" bash "$TOOL" --mode emmc --variant "$VARIANT" --yes
    t M2 "--variant does not match the board PMIC" "variant guard" sudo env ROOT_DIR="$PKG" bash "$TOOL" --mode emmc --variant "$WRONG" --yes
    t M3 "operator answers 'n' at the prompt" "aborted by operator" sh -c "echo n | sudo env ROOT_DIR='$PKG' bash '$TOOL' --mode emmc --variant $VARIANT"
else
    s M1-3 "no ${MMC}boot0 (booted from SD; eMMC not visible)"
fi

section "restore path (--restore <run-id>)"
t FR1 "restore from a run that does not exist" "no backup run" sudo bash "$TOOL" --restore no-such-run --yes
t FR2 "restore combined with --mode" "takes no --mode" sudo bash "$TOOL" --restore no-such-run --mode qspi --yes
if [ -n "$RUN" ] && sudo test -d "$BK/$RUN"; then
    c=suite-corrupt-$$
    sudo cp -a "$BK/$RUN" "$BK/$c"
    sudo bash -c "$(declare -f flip); flip '$BK/$c/fip.img' 5000"
    t FR3 "restore from a run whose fip.img is corrupt" "backup corrupt" sudo bash "$TOOL" --restore "$c" --yes
    sudo rm -rf "${BK:?}/$c"
    if sudo grep -q '/dev/mtd' "$BK/$RUN/fip.meta"; then
        t FR4 "restore with the QSPI fip label not matching" "mtd layout guard" sudo env MTD_FIP_LABEL=notfip bash "$TOOL" --restore "$RUN" --yes
    else
        s FR4 "run $RUN is not a QSPI backup"
    fi
    t FR5 "operator answers 'n' at the restore prompt" "aborted by operator" sh -c "echo n | sudo bash '$TOOL' --restore '$RUN'"
    c=suite-half-$$
    sudo cp -a "$BK/$RUN" "$BK/$c"
    sudo sh -c "rm -f '$BK/$c'/*.meta"
    t FR6 "restore from a run with an .img but no .meta" "but not both" sudo bash "$TOOL" --restore "$c" --yes
    sudo rm -rf "${BK:?}/$c"
    c=suite-redirect-$$
    sudo cp -a "$BK/$RUN" "$BK/$c"
    sudo sh -c "for m in '$BK/$c'/*.meta; do sed -i 's|^target\t.*|target\t/dev/mtd2|' \"\$m\"; done"
    t FR7 "restore whose .meta names a non-bootchain target" "not a bootchain location" sudo bash "$TOOL" --restore "$c" --yes
    sudo rm -rf "${BK:?}/$c"
else
    s FR3-7 "need --restore-run <id> from $BK (sudo ls $BK)"
fi

section "dry-runs (informational, not scored)"
echo "-- qspi"
sudo env ROOT_DIR="$PKG" bash "$TOOL" --mode qspi --variant "$VARIANT" --dry-run 2>&1 | grep -E "QSPI FIP|skipping|DRY-RUN|complete"
if [ "$HAVE_BOOT0" -eq 1 ]; then
    echo "-- emmc"
    sudo env ROOT_DIR="$PKG" bash "$TOOL" --mode emmc --variant "$VARIANT" --dry-run 2>&1 | grep -E "skipping|DRY-RUN|complete"
else
    echo "-- esd"
    sudo env ROOT_DIR="$PKG" bash "$TOOL" --mode esd --variant "$VARIANT" --dry-run 2>&1 | grep -E "skipping|DRY-RUN|complete"
fi

rm -rf "${WORK:?}"
echo
if [ "$(inv)" = "$I0" ]; then echo "storage unchanged across the whole run"; else echo "STORAGE CHANGED: $(inv)"; fail=$((fail + 1)); fi
echo "TOTAL pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]

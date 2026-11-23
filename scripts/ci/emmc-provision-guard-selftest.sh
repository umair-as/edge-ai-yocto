#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Host self-test for the target guards in scripts/dev/edge-emmc-provision.sh,
# against a fake sysfs tree. Block-device tests, findmnt, id and every writer
# are mocked through BASH_ENV; dd returns sentinel 97, so "reached the write"
# is exit 97. No device is read or written. Exit 0 when every case passes.
set -u

ROOT=$(git rev-parse --show-toplevel) || exit 1
TOOL="$ROOT/scripts/dev/edge-emmc-provision.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
n=0

# Fake sysfs: mmcblk0 (target eMMC, p1..p4), mmcblk1 (SD, p1..p2),
# dm-0 = verity over mmcblk0p3, dm-1 = dm over dm-0, dm-2 = verity over
# mmcblk1p2, loop0 over mmcblk0p4, loop1 over mmcblk1p1. A dm device
# registers itself under its slaves' holders/, as the kernel does.
S="$T/sys"
mkdir -p "$S/dev/block" "$S/class/block"
disk() { # disk <name> <maj:min> <parent dir>
    mkdir -p "$3/$1"; echo "$2" > "$3/$1/dev"
    ln -s "$3/$1" "$S/dev/block/$2"; ln -s "$3/$1" "$S/class/block/$1"
}
part() { # part <disk dir> <name> <maj:min> <n>
    mkdir -p "$1/$2"; echo "$3" > "$1/$2/dev"; echo "$4" > "$1/$2/partition"
    ln -s "$1/$2" "$S/dev/block/$3"; ln -s "$1/$2" "$S/class/block/$2"
}
dm() { # dm <name> <maj:min> <slave name>...
    local name=$1 mm=$2; shift 2
    disk "$name" "$mm" "$S/devices/virtual/block"
    mkdir -p "$S/devices/virtual/block/$name/slaves"
    for s in "$@"; do
        ln -s "$(readlink -f "$S/class/block/$s")" "$S/devices/virtual/block/$name/slaves/$s"
        mkdir -p "$(readlink -f "$S/class/block/$s")/holders"
        ln -s "$S/devices/virtual/block/$name" "$(readlink -f "$S/class/block/$s")/holders/$name"
    done
}
loopdev() { # loopdev <name> <maj:min> <backing block device>
    disk "$1" "$2" "$S/devices/virtual/block"
    mkdir -p "$S/devices/virtual/block/$1/loop"
    echo "$3" > "$S/devices/virtual/block/$1/loop/backing_file"
}
disk mmcblk0 179:0 "$S/devices/mmc0/block"
for i in 1 2 3 4; do part "$S/devices/mmc0/block/mmcblk0" "mmcblk0p$i" "179:$i" "$i"; done
disk mmcblk1 179:32 "$S/devices/mmc1/block"
for i in 1 2; do part "$S/devices/mmc1/block/mmcblk1" "mmcblk1p$i" "179:$((32 + i))" "$i"; done
loopdev loop0 7:0 /dev/mmcblk0p4
loopdev loop1 7:1 /dev/mmcblk1p1
dm dm-2 252:2 mmcblk1p2
# A second tree in which the target eMMC carries dm-verity: built per case.
mkdir -p "$T/dev/by-id"
: > "$T/dev/mmcblk0"; : > "$T/dev/mmcblk0p3"
ln -s "$T/dev/mmcblk0" "$T/dev/by-id/mmc-EMMC"
: > "$T/image.wic"
mkdir -p "$T/proc"

cat > "$T/mocks" <<'MOCK'
id() { echo 0; }
[() {
    if builtin [ "${1:-}" = -b ]; then builtin [ -e "$2" ] || [[ "$2" == /dev/* ]]; return; fi
    builtin [ "$@"
}
findmnt() {
    builtin [ "${FAKE_FINDMNT_FAIL:-0}" = 1 ] && return 1
    case "$*" in
        *MAJ:MIN,FSTYPE,TARGET*) printf '%b' "$FAKE_MOUNTS" ;;
        *"-o MAJ:MIN /"*) printf '%s  \n' "$FAKE_ROOT_MM" ;;
        *"-o SOURCE /"*) echo "$FAKE_ROOT_SRC" ;;
    esac
}
dd() { echo "MOCK_DD_REACHED $*" >&2; return 97; }
partprobe() { return 0; }
sfdisk() { return 0; }
MOCK

# case_ <expected exit> <name> <target> <root mm> <root src> <mounts>
# SWAPS (default none) is the body of /proc/swaps; DM=1 adds dm-0/dm-1 over
# the target to the sysfs tree for the case.
case_() {
    n=$((n + 1))
    printf 'Filename Type Size Used Priority\n%b' "${SWAPS:-}" > "$T/proc/swaps"
    rm -rf "$S/devices/virtual/block/dm-0" "$S/devices/virtual/block/dm-1" \
        "$S/dev/block/252:0" "$S/dev/block/252:1" "$S/class/block/dm-0" "$S/class/block/dm-1"
    find "$S/devices/mmc0" -path '*/holders/dm-*' -delete 2>/dev/null
    if [ "${DM:-0}" = 1 ]; then dm dm-0 252:0 mmcblk0p3; dm dm-1 252:1 dm-0; fi
    out=$(BASH_ENV="$T/mocks" EDGE_SYSFS="$S" EDGE_PROC="$T/proc" FAKE_ROOT_MM="$4" FAKE_ROOT_SRC="$5" \
          FAKE_MOUNTS="$6" FAKE_FINDMNT_FAIL="${FAIL:-0}" \
          bash "$TOOL" --wic "$T/image.wic" --target "$3" --yes 2>&1)
    rc=$?
    if [ "$rc" = "$1" ]; then printf '  ok   %s\n' "$2"
    else printf '  FAIL %s (expected exit %s, got %s)\n%s\n' "$2" "$1" "$rc" "$out" | head -8
         fails=$((fails + 1)); fi
}

EMMC="$T/dev/mmcblk0"
SD='179:34 ext4 /\n0:22 tmpfs /run\n179:33 vfat /boot\n'
case_ 1  "root on a raw target partition"       "$EMMC" 179:3 /dev/mmcblk0p3 '179:3 ext4 /\n'
DM=1 case_ 1 "dm-verity root over the target"   "$EMMC" 252:0 /dev/dm-0 '252:0 ext4 /\n'
DM=1 case_ 1 "dm over dm over the target"       "$EMMC" 252:1 /dev/mapper/x '252:1 ext4 /\n'
DM=1 case_ 1 "target given as a by-id alias"    "$T/dev/by-id/mmc-EMMC" 252:0 /dev/mapper/vroot '252:0 ext4 /\n'
DM=1 case_ 1 "unmounted dm mapping on the target (holder)" "$EMMC" 179:34 /dev/mmcblk1p2 "$SD"
case_ 1  "root on SD, /data on the target"      "$EMMC" 179:34 /dev/mmcblk1p2 "${SD}179:4 ext4 /data\n"
case_ 1  "loop over a target partition mounted" "$EMMC" 179:34 /dev/mmcblk1p2 "${SD}7:0 ext4 /mnt\n"
SWAPS='/dev/mmcblk0p4 partition 1024 0 -2\n' \
case_ 1  "swap on a target partition"           "$EMMC" 179:34 /dev/mmcblk1p2 "$SD"
case_ 1  "btrfs on an anonymous device"         "$EMMC" 179:34 /dev/mmcblk1p2 "${SD}0:45 btrfs /srv\n"
case_ 1  "partition given as the target"        "$T/dev/mmcblk0p3" 179:34 /dev/mmcblk1p2 "$SD"
case_ 1  "unresolvable root device"             "$EMMC" 9:9 /dev/md9 '9:9 ext4 /\n'
case_ 1  "empty findmnt for /"                  "$EMMC" "" "" "$SD"
FAIL=1 case_ 1 "findmnt fails"                  "$EMMC" 179:34 /dev/mmcblk1p2 "$SD"
case_ 97 "root on SD: write reached"            "$EMMC" 179:34 /dev/mmcblk1p2 "$SD"
case_ 97 "dm-verity root on SD: write reached"  "$EMMC" 252:2 /dev/dm-2 '252:2 ext4 /\n0:22 tmpfs /run\n'
SWAPS='/dev/mmcblk1p1 partition 1024 0 -2\n' \
case_ 97 "swap and a loop on SD: write reached" "$EMMC" 179:34 /dev/mmcblk1p2 "${SD}7:1 ext4 /mnt\n"

printf '%d cases, %d failed\n' "$n" "$fails"
[ "$fails" -eq 0 ]

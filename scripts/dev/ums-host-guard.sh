#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Host side of U-Boot `ums`: a udev rule that makes udisks ignore the U-Boot
# mass-storage gadget (USB ID 0000:0000), so the desktop never auto-mounts the
# board's exported eMMC or microSD while it is being written. `ums` has no
# read-only mode.
#
#   ums-host-guard.sh on|off|status
set -euo pipefail

RULE=/etc/udev/rules.d/99-edge-uboot-ums-ignore.rules

case "${1:-}" in
    on)
        echo 'SUBSYSTEM=="block", ENV{ID_VENDOR_ID}=="0000", ENV{ID_MODEL_ID}=="0000", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"' \
            | sudo tee "$RULE" >/dev/null
        sudo udevadm control --reload ;;
    off)
        sudo rm -f "$RULE"
        sudo udevadm control --reload ;;
    status) ;;
    *) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
echo "rule: $(cat "$RULE" 2>/dev/null || echo absent)"

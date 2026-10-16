#!/bin/sh
# SPDX-License-Identifier: MIT
# Bootloader bundle hook. The checks live in the installed rootfs; the RZ/V2L
# pre-install handler refuses a bundle whose hook differs from this file.
exec /usr/lib/rzv2l-bootchain/slot-hook "$@"

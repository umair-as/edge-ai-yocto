# eMMC install, update and recovery — Arduino VENTUNO Q

The VENTUNO Q (`BOARD=ventuno-q`, Qualcomm QCS8275) boots its eMMC through the
vendor firmware and UEFI, which this build neither produces nor writes
([ADR-0016](../../adr/0016-ventuno-q-uefi-uki-boot-chain.md)). The image is
installed over USB in the SoC's emergency download mode (EDL) with
`scripts/dev/ventunoq-flash.py`, and updated with RAUC bundles.

Hardware-validated 2026-11-11: install, first boot, signed bundle install and
confirmation, automatic fallback from a failing update, and recovery after an
update.

## What goes where

The factory GPT keeps partitions 1–70 and their contents; the slots are carved
from the factory `system` partition.

| # | Partition | Content | Written by |
|---|---|---|---|
| 69 | `efi` (factory ESP) | systemd-boot, `loader.conf`, both slot UKIs, the firmware's own files | install, recovery; slot UKIs by RAUC |
| 71, 72 | `efiA`, `efiB` | empty file systems (reserved) | install |
| 73, 74 | `rootfsA`, `rootfsB` | `ext4.verity` | install, recovery, RAUC |
| 75 | `data` | `/data` | install (seed, grown on first boot) |

Each slot boots a unified kernel image (UKI) holding the kernel, the board DTB
and a command line with that slot's dm-verity table. systemd-boot picks the slot
from the UKI file names in `\EFI\Linux\` (`edge-<generation>-<slot>[+tries].efi`);
no EFI variable takes part in slot selection.

## Prerequisites

- The board's USB-C port cabled to the host for data; power from the 12 V
  supply.
- A jumper on JCTL pins 1–2 to enter EDL at power-on. EDL shows on the host as
  USB `05c6:9008`.
- `qdl` and the Qualcomm Firehose programmer for this board (from the vendor's
  factory image; Qualcomm binaries are not built or redistributed here).
- Host settings in `${XDG_CONFIG_HOME:-~/.config}/edge-ai/ventunoq.conf`
  (`KEY=value`): `QDL`, `FIREHOSE`, `SERIAL` (the unit's EDL serial), and
  optionally `UNIT_DIR`, `BUILD_DIR`.
- The unit's own GPT and ESP, dumped once over EDL and imported:

  ```bash
  scripts/dev/ventunoq-flash.py import-unit --gpt <gpt-primary.bin> \
      --esp <p69 dump> --esp-source pristine
  ```

  The install set's GPT keeps the unit's entries 1–70 byte for byte, and its
  ESP starts from the unit's ESP so the firmware's files survive. The ESP dump
  carries the firmware's variable store file; the install resets the store to
  that file.

## Install

```bash
make dev BOARD=ventuno-q
scripts/dev/ventunoq-flash.py flash            # jumper on, board powered
```

`flash` assembles an install set for the current build under
`build/ventuno-q/install/<IMAGE_NAME>/` (GPT, ESP, slot and data images, and a
`MANIFEST.json` with every file's sha256), or reuses that build's verified set,
then waits for the EDL device and runs `qdl`. A set is never reused for another
build. `/data` is written from the seed image, so it is lost.

Remove the jumper and power-cycle. With no `BootOrder`, the firmware boots
systemd-boot from the ESP's removable-media path, which boots slot A. Check the
console log against the set:

```bash
scripts/dev/ventunoq-flash.py verify-boot --log <console log>
```

On first boot `edge-grow-data` grows `/data` to the end of the eMMC, and
`rauc-mark-good` confirms slot A.

## Verification (on the board)

```
rauc status                                   # slot A booted and good
bootctl status                                # systemd-boot, current entry edge-2-a.efi
ls /boot/EFI/Linux                            # one entry per slot
/usr/libexec/edge-sdboot-backend get-primary  # A
df -h /data                                   # grown to the eMMC
```

`scripts/dev/edge-verity-check.sh` checks the verity mapping, the systemd-boot
entries, the absence of `BootNext` and loader default variables, and the RAUC
state.

## Updates

```bash
make bundle BOARD=ventuno-q
```

The bundle carries the rootfs and both slot UKIs. Copy it to the board's `/data`
and install it:

```
rauc install /data/<bundle>.raucb
reboot
```

RAUC marks the inactive slot bad, writes its rootfs, and the bundle hook places
that slot's UKI on the ESP under the slot's entry name. RAUC then activates the
slot through `/usr/libexec/edge-sdboot-backend`, which renames the entry to the
next generation with three boot attempts. systemd-boot counts each attempt in
the file name. `rauc-mark-good` confirms a slot that reaches userspace and marks
the other slot bad. A slot that resets three times before confirmation (a kernel
panic, a dm-verity failure) sorts last, and the previous slot boots.

The ESP's loader is not updated by a bundle: `systemd-boot-update.service` is
disabled, and the loader is installed with the image.

## Recovery

Recovery is an attended EDL write from an install set, with the jumper fitted:

```bash
scripts/dev/ventunoq-flash.py flash --only recover --set <install set>
```

`--only recover` writes the ESP and both rootfs slots from one set, so each slot
again has a rootfs and UKI from the same build, whatever updates ran before.
`/data` and `efiA`/`efiB` are not written. Slot A boots afterwards. RAUC's
record of the last install in `/data/rauc` is kept and still describes that
install until RAUC installs into the slot again.

The set can be older than the build the unit runs: `--allow-other-build` lets
`flash` write a set that is not the current build's. Both slots then run that
set's build, a downgrade when the unit was updated past it; `/data` is kept as
the newer software left it. Install sets under `build/ventuno-q/install/` are
the only source for an older build: the deploy directory holds only the latest
build, and `flash` refuses a set whose files no longer match its `MANIFEST.json`.
`--only recover` takes only sets built for the custom RAUC backend; for any
other set, a full `flash` is the recovery, and it overwrites `/data`.

`--only esp` writes the ESP alone, which restores the loader, `loader.conf` and
the variable store. It is a recovery only while both rootfs slots still hold the
set's rootfs: after an update, the restored UKIs carry the set's root hash and a
slot booted with them fails dm-verity on every boot.

Restoring the vendor's factory image (stock OS) goes through the same EDL path,
with the vendor's `arduino-flasher-cli` (hardware-validated 2026-11-12, factory
build 20260710-235: flash complete, stock OS boots). The allowlist restore that
follows it (ADR-0016 §4: `persist` from the per-unit backup after checking the
other unit partitions) has not been run on this board.

## Limitations

- No secure boot: nothing verifies the UKI, so dm-verity detects corruption and
  does not authenticate the rootfs (ADR-0016 §2). Prod images stop at the
  trust-anchor gate by design; the board builds dev images.
- The image does not configure `wlan0` for the M.2 Wi-Fi card (QCA2066); a
  network unit and a `wpa_supplicant` configuration are supplied at runtime.
- NPU inference is not integrated: the image builds without an accelerator
  stack (`EDGE_ALLOW_NO_ACCEL`). The Hexagon DSPs run and their FastRPC device
  nodes and daemons are present, but no inference runtime is installed.
- A slot that hangs before userspace without resetting is not caught: no
  watchdog runs before Linux.

## Roadmap

- NPU inference on the Hexagon NPU: an inference runtime (QNN, ONNX Runtime
  with the QNN execution provider) in an accelerator stack composed by the
  board, inference proven to run on the NPU, then the same workload rootless as
  `edge-ctr`; `EDGE_ALLOW_NO_ACCEL` is then dropped.
- Programming the STM32H5 co-processor from the image (the vendor uses
  `arduino-cli`).
- A prod tier: a trust anchor for the UKIs and a KSPP kernel-config baseline.

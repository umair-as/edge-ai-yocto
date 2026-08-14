# A/B OTA updates (RAUC + U-Boot)

How the edge distro ships updates: two rootfs slots, atomic RAUC install to the
inactive one, and automatic bootloader rollback if the new slot fails to boot.

This is the single reference for the update + rollback story. The failure-mode
test campaign that validates it lives in
[`ota-rollback-test-plan.md`](ota-rollback-test-plan.md); the architectural
decisions are in [`adr/0005-image-class-ota-backend.md`](../adr/0005-image-class-ota-backend.md)
and [`adr/0006-emmc-gpt-boot-target.md`](../adr/0006-emmc-gpt-boot-target.md).

## Layout

| Partition | Role |
|-----------|------|
| `mmcblk0p1` (`/boot`) | Shared filesystem containing signed `fitImage-A` and `fitImage-B` |
| `mmcblk0p2` (rootfs A, `rootfs.0`) | Slot A ext4 data + appended Merkle tree |
| `mmcblk0p3` (rootfs B, `rootfs.1`) | Slot B ext4 data + appended Merkle tree |
| `mmcblk0p4` (`/data`) | Persistent state, shared across slots |

`/boot` is shared, but each slot has its own FIT. The FIT signature covers the
slot's kernel, DTB, root hash, and `dm-mod.create` policy.

## Mechanism

RAUC drives the install; U-Boot's environment state machine drives slot
selection and rollback.

- **RAUC** (`meta-edge-bsp/recipes-ota/rauc/files/system.conf`): `bootloader=uboot`,
  `boot-attempts=3`, slots `rootfs.0`/`A` and `rootfs.1`/`B`. Install marks the
  target slot bad *before* writing and active *only* after a fully successful
  install (write + hooks).
- **U-Boot** (`meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults`):
  `rauc_select_slot` walks `BOOT_ORDER`, picks the first slot with
  `BOOT_<slot>_LEFT > 0`, decrements that counter, and `saveenv`s the decrement
  **before** `bootm` — so a slot that hangs or crashes mid-boot still consumes an
  attempt. When a slot's counter hits 0, the next slot in `BOOT_ORDER` is tried.
  `rauc_validate_slot` resets the counters and reboots if no slot has attempts
  left (the both-bad backstop).
- **Confirm** (`rauc-mark-good.service`, upstream meta-rauc): on a good boot it
  resets the booted slot's counter, making it sticky. It runs **early and
  unconditionally** — it does not gate on workload health.

### Update flow

1. `rauc install bundle.raucb` — verify signature, mark the target bad, raw-write
   `ext4.verity`, atomically replace only its signed FIT, mark its environment
   flag verity-ready, then activate it.
2. Reboot — U-Boot selects the new slot, decrements its counter, boots it.
3. On a healthy boot, `rauc-mark-good` resets the counter; the slot is now
   sticky. On a failed boot, the counter exhausts and U-Boot falls back.

## Rollback semantics

Rollback is **boot-count / bootchooser level** — it triggers on a slot that
fails to *boot*, not on a workload that fails *after* boot.

- **Caught:** a slot that panics or fails before `rauc-mark-good` runs. The
  kernel is built with `CONFIG_PANIC_TIMEOUT=10`, so a panicking slot self-reboots
  in 10 s and re-enters U-Boot with the counter already decremented; after
  `boot-attempts` failures U-Boot boots the other slot. No `panic=` cmdline arg
  or watchdog dependency is needed.
- **Not caught:** a slot that boots far enough for the early `rauc-mark-good` to
  run, then whose *workload* fails. The counter is already reset, so no revert.
  Health-gated confirm-boot (`virtual-ota-confirm-boot`) is deferred — see
  ADR-0005. "Automatic rollback" here means boot integrity, not application
  health.

## Hardware validation

Validated on the RZ/V2L SMARC EVK (2026-07; full detail and evidence in the
[test plan](ota-rollback-test-plan.md)):

| Path | Result |
|------|--------|
| Corrupt slot → bootcount revert to last-good | PASS (T1) |
| Same, as-shipped cmdline (no `panic=`) | PASS (T2) — `CONFIG_PANIC_TIMEOUT` self-reboots |
| Interrupted install (daemon killed mid-write) leaves active slot intact | PASS (T3) |
| Failed post-install hook aborts install, target never activated | PASS (T6) |
| Both-slots-exhausted backstop self-heals | PASS (T7) |
| Workload failure after boot does **not** revert (documents the gap) | PASS (T8) |

The failure→revert round-trip is therefore hardware-validated for boot-time
failures. Power-loss atomicity (mid-write, mid-env-write) is designed-safe on
RAUC's atomic marking + redundant U-Boot env but not yet bench-tested.

## Kernel and root-hash coupling

A bundle always carries the rootfs plus both image-specific FIT artifacts. The
post-install hook writes only the target slot FIT, and fails before activation
if it is absent. This makes the kernel, modules, DTB, root hash, and verity
geometry one release unit.

The requirement comes from an earlier hardware failure where a rootfs-only
bundle used modules built against a different shared kernel:

- The kernel version string is identical, so **vermagic passes and the module
  loader accepts** the drifted out-of-tree modules (`vspm`, `mmngr`, `drpai`,
  `mmngrbuf`, `u_dma_buf`).
- `resolve_symbol` then links them against a mismatched symbol table, corrupting
  a kernel list; `CONFIG_DEBUG_LIST` catches it as
  `kernel BUG at lib/list_debug.c:29` → `Kernel panic`.
- The panic reboots (via `CONFIG_PANIC_TIMEOUT`); after `boot-attempts` the
  bootcount reverts to the previous slot. Observed on hardware (2026-07-09): a
  freshly-installed slot panicked at t≈10 s in `systemd-modules-load` and rolled
  back automatically.

The paired-FIT bundle closes that coupling gap. During migration, a slot without
an `EDGE_VERITY_<slot>=1` marker may still use the legacy shared FIT. Updating
both slots removes that transitional path from normal selection.

### Migration from the pre-verity layout

Flash one complete WIC image before installing verity bundles. The old running
system declares RAUC slots as `type=ext4`; handler selection uses that installed
configuration and is not changed by the incoming rootfs. The new baseline
declares `type=raw`, contains both slot FITs, and has SELinux labels applied
before its Merkle trees are generated. Once that baseline is running, normal
RAUC A/B updates remain supported.

## Building and installing a bundle

```bash
make bundle                       # -> build/tmp/deploy/images/<machine>/edge-image-dev-bundle.raucb
```

On the target (device `/data` is not user-writable — stage in the operator's
home, which is `/data`-backed):

```bash
scp edge-image-dev-bundle.raucb devel@<board>:/home/devel/
sudo rauc install /home/devel/edge-image-dev-bundle.raucb
sudo reboot                       # flips to the new slot
```

Notes:

- The full ext4 write to eMMC takes several minutes; the `rauc.service` daemon
  completes the install even if the `rauc install` client is disconnected —
  track completion with `journalctl -u rauc.service` by installation ID.
- mTLS HTTPS streaming install is wired and hardware-validated. `rauc install
  https://<host>/bundles/<bundle>.raucb` streams the bundle over TLS with a
  client certificate — RAUC starts an NBD server, reads the remote bundle in
  place, and writes straight into the inactive slot. No local copy of the
  bundle is needed, so a 253 MB bundle installs on a device with no room to
  stage it.

  The transfer drops privileges to the `ota` user (`sandbox-user=ota` in
  `system.conf`); the bundle signature is verified over the stream before any
  slot is touched.

  The device identity is **not** shipped by default. Provision it by staging a
  CA cert, client cert and key into one directory and pointing the build at it:

  ```bash
  scripts/ota/stage-device-certs.sh \
      --ca ca.crt --cert <device>.crt --key <device>.key
  # then, in kas/local.yml:
  #   EDGE_OTA_CERT_DIR = "<staged-dir>"
  ```

  The script refuses material that would fail at handshake time — key not
  matching the cert, a chain that does not verify against the CA, or an expired
  cert — because those otherwise surface only as a TLS error mid-install. The
  files land in `/etc/ota` as `root:ota`, with the key at `0640` so the
  sandboxed transfer user can read it.

## References

- [`ota-rollback-test-plan.md`](ota-rollback-test-plan.md) — failure-injection tests + results.
- [`adr/0005-image-class-ota-backend.md`](../adr/0005-image-class-ota-backend.md) — backend abstraction, deferred confirm-boot.
- [`adr/0006-emmc-gpt-boot-target.md`](../adr/0006-emmc-gpt-boot-target.md) — boot layout, env location.
- [`security/uboot-hardening.md`](../security/uboot-hardening.md) — U-Boot env + bootcount variables.
- `meta-edge-bsp/recipes-ota/rauc/files/system.conf`, `.../rauc-uboot-env.defaults` — the wiring.

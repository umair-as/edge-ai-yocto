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

## Encrypted bundles (crypt format)

**Status: wired and recipe-verified, not hardware-validated.** The image side is
built and inspected: with encryption enabled the rendered `system.conf` carries
`bundle-formats=verity crypt` and an `[encryption]` block, and the recipient key
installs as `/etc/ota/bundle-decrypt.key` with mode `0640`. The kernel side was
verified against a built config. **No encrypted bundle has been produced from
this tree and no device has installed one** — every claim below about install
behaviour describes intended behaviour, not measured behaviour.

Default bundles are `verity` format: signed and integrity-protected, but the
payload is readable by anyone holding the file. The `crypt` format adds
confidentiality — RAUC encrypts the payload SquashFS with AES-256
(`aes-cbc-plain64`) and CMS-envelopes the manifest carrying that key to a set
of recipient certificates. The device decrypts with the matching private key,
via the kernel's dm-crypt target stacked under the existing dm-verity mapping.

The recipient PKI is independent of the bundle-signing PKI: signatures still
chain to `/etc/rauc/ca.cert.pem`, and encryption is a separate set of
certificates.

### Enabling it

Two device-side prerequisites gate a crypt install, and both ship *inside the
image*: the recipient private key, and a `bundle-formats` allowlist naming
`crypt`. A device running an older image has neither, so the first encrypted
bundle it is offered would be rejected. The rollout therefore delivers an
encryption-ready image first, over an ordinary verity bundle, and only then
switches the bundle format. No reflash is required.

1. Generate the dev PKI (idempotent; adds the recipient keypair to the
   signing CA and leaf it already emits):

   ```bash
   scripts/rauc-init-certs.sh
   ```

2. **Transition release — encryption-ready image, still a verity bundle.**

   ```
   EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION = "1"
   EDGE_RAUC_BUNDLE_FORMAT            = "verity"
   ```

   ```bash
   make dev
   make bundle
   ```

   The image now carries `/etc/ota/bundle-decrypt.key` and a
   `bundle-formats=verity crypt` allowlist; the bundle is still verity, so
   fielded devices accept it. Install it over the normal OTA path.

   `edge-floor.inc` defaults the recipient paths to what the script wrote, so
   nothing else is required for the dev flow. `kas/local.yml.example` lists
   every override, including the PKCS#11 variant.

3. **Once the fleet is on that image, drop the format override.** Bundles
   become `crypt`; devices already hold the key and already accept the format.

   ```
   EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION = "1"
   ```

   ```bash
   make bundle
   ```

4. **Optional later hardening.** Narrowing the allowlist stops a device
   accepting unencrypted bundles at all:

   ```
   EDGE_RAUC_BUNDLE_FORMATS = "crypt"
   ```

   This is fail-closed and one-way in practice: a device that accepts only
   `crypt` can no longer be reached by a verity bundle, so it is safe only
   once every device in the fleet is past step 3. It also requires another
   image update to take effect, since the allowlist ships in the image.

The bundle keeps its usual filename — `rauc encrypt` runs in place, so the
key-bearing intermediate (a crypt bundle whose manifest still holds the
plaintext payload key) is never deployed.

### What the operator supplies

| Artifact | Default source | Lands on device as |
|---|---|---|
| Recipient certs, `rauc encrypt --to` | `keys/dev/rauc/rauc-recipients.pem` | not installed — build-host only |
| Recipient private key | `keys/dev/rauc/rauc-recipient.key` | `/etc/ota/bundle-decrypt.key`, `root:ota`, `0640` |
| Recipient cert | `keys/dev/rauc/rauc-recipient.cert.pem` | `/etc/ota/bundle-decrypt.cert.pem`, `root:ota`, `0644` |

`cert=` is optional in RAUC's `[encryption]` block; it only speeds recipient
lookup. `key=` is mandatory and may instead be a `pkcs11:` URI, in which case
no key file is installed.

Build-time guards fail the build rather than emit a bundle no device can
install: a `bundle-formats` list without `crypt`, or an `[encryption] key=`
filesystem path that nothing provisions into the image. On a build that
actually emits a crypt bundle, a missing or unset recipients file is also
fatal. The transition build of step 2 emits `verity`, so the encryption pass
is skipped entirely — `rauc encrypt` refuses a non-crypt input — and the build
logs a note saying the bundle it produced is unencrypted.

### Known limits

- One shared recipient key for the whole fleet in the dev flow. Planned
  rotation is possible by encrypting to the old and new recipients during an
  overlap window, but both A/B slots must migrate before the old recipient is
  removed. A compromised shared key cannot be recovered securely over a bundle
  it can decrypt; that case requires trusted reprovisioning or reflashing.
  Per-device recipients require a build-external encryption step.
- The recipient private key sits in the rootfs, protected by file permissions
  and the read-only dm-verity mapping. Binding it to the device (PKCS#11 via
  OP-TEE or TPM2) is the L5 work described in
  [ADR-0003](../adr/0003-block-layer-integrity-confidentiality.md).
- Adaptive updates (`EDGE_RAUC_ADAPTIVE`) have not been exercised against a
  crypt bundle.

The recipient-key lifecycle, including rotation, rollback-slot compatibility,
and the production per-device direction, is recorded in
[ADR-0009](../adr/0009-rauc-encrypted-bundle-key-lifecycle.md).

## References

- [`ota-rollback-test-plan.md`](ota-rollback-test-plan.md) — failure-injection tests + results.
- [`adr/0005-image-class-ota-backend.md`](../adr/0005-image-class-ota-backend.md) — backend abstraction, deferred confirm-boot.
- [`adr/0006-emmc-gpt-boot-target.md`](../adr/0006-emmc-gpt-boot-target.md) — boot layout, env location.
- [`security/uboot-hardening.md`](../security/uboot-hardening.md) — U-Boot env + bootcount variables.
- `meta-edge-bsp/recipes-ota/rauc/files/system.conf`, `.../rauc-uboot-env.defaults` — the wiring.

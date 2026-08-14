# A/B OTA rollback — failure-injection test plan

How to validate the RAUC A/B update *failure* paths on RZ/V2L hardware: not
that an update installs, but that a **bad** update, an interrupted install, or
a power loss leaves the board on a known-good slot.

This backs the CRA availability control (`docs/security/CRA-CONTROLS.md`, 8.a —
"A/B rootfs with rollback"). The success path (install → boot new slot →
mark-good) is exercised by every OTA smoke test; this plan covers the paths a
smoke test never triggers.

## Witnessed vs. designed

Each test carries a class, because "not yet captured" is not the same as
"broken":

- **Witnessed** — a serial capture on real silicon shows the path working.
- **Designed-safe** — the behavior follows standard RAUC/U-Boot semantics with
  high confidence, but no capture exists yet. A test moves it to *witnessed*.
- **Known gap** — the current design does *not* do what a naive reading of
  "automatic rollback" implies. The test's job is to document the boundary, not
  to pass.

## Three axes

The failure modes live on three independent axes. A test on one says nothing
about the others.

| Axis | Question | Trigger point |
|------|----------|---------------|
| Boot-time slot selection | Does a slot that won't boot get abandoned? | U-Boot `bootcmd`, per boot |
| Install-time atomicity | Does an interrupted/failed install leave the active slot intact? | `rauc install`, during the write/activate window |
| Runtime health | Does a slot that boots but whose workload fails get reverted? | after `rauc-mark-good`, at runtime |

## Mechanism under test

Slot selection is a U-Boot env state machine
(`meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults`):

- `rauc_select_slot` walks `BOOT_ORDER`, picks the first slot with
  `BOOT_<slot>_LEFT > 0`, decrements that counter, and `saveenv` persists the
  decrement **before** `bootm` — so a crash mid-boot still consumes an attempt.
- When the chosen slot's counter reaches 0, the loop skips it and takes the next
  slot in `BOOT_ORDER`.
- `rauc_validate_slot` resets both counters and reboots if no slot has attempts
  left (the both-bad backstop).
- On a good boot, `rauc-mark-good.service` resets the booted slot's counter.
  This service is **early and unconditional** — it does not gate on workload
  health (`virtual-ota-confirm-boot` is deferred, `docs/adr/0005-image-class-ota-backend.md`).

Two facts that shape the tests:

- The as-shipped kernel cmdline has no `panic=`, but the kernel is **built with
  `CONFIG_PANIC_TIMEOUT=10`** — a slot that panics at rootfs-mount prints
  `Rebooting in 10 seconds` and self-reboots into U-Boot on its own, consuming
  a boot attempt each time (verified in T2). The U-Boot watchdog
  (`watchdog@12800800`, 60 s) is only a secondary backstop for a true hang that
  never panics. A cmdline `panic=` is therefore **not** required for rollback.
- `/boot` is a shared filesystem, but `fitImage-A` and `fitImage-B` are updated
  independently. Filesystem-wide corruption can still affect both slots; a
  failed inactive-slot FIT replacement must not modify the active slot FIT.

## Test matrix

| ID | Axis | Injection | Expected result | Class | Method |
|----|------|-----------|-----------------|-------|--------|
| T1 | boot select | Corrupt inactive slot rootfs superblock; `panic=5` added | 3 failed attempts on the bad slot → counter 3→0 → revert to good slot, boots clean | **Witnessed** (2026-07-08) | software |
| T2 | boot select | T1 without any `panic=` (as-shipped cmdline) | Kernel's built-in `CONFIG_PANIC_TIMEOUT=10` self-reboots each attempt → counter 3→0 → revert. No `panic=` or watchdog needed. | **Witnessed** (2026-07-08) | software |
| T3 | install atomic | Kill `rauc` (SIGKILL) mid rootfs-write | Target stays `bad`; active slot unchanged; next boot = active slot | Designed-safe | software |
| T4 | install atomic | Cut board power mid rootfs-write | As T3 — board comes up on the active good slot | Designed-safe | **hardware** |
| T5 | install atomic | Cut power during activate/env-write window | Redundant env (CRC'd A/B copies) stays consistent; boots active slot | Designed-safe | **hardware** |
| T6 | install atomic | Bundle whose post-install hook exits non-zero | Install aborts; target never marked active; active slot unchanged | Designed-safe | software (needs bad-hook bundle) |
| T7 | boot select | Set `BOOT_A_LEFT=0 BOOT_B_LEFT=0` (no corruption) | `rauc_validate_slot` prints reset message, resets counters, one extra reboot, then boots normally | Designed-safe | software |
| T8 | runtime health | Break a critical unit on the good slot, reboot | **No revert** — slot already mark-good'd, counter reset. Confirms rollback is not health-gated. | **Known gap** | software |

`panic=5` in T1 makes each attempt reboot in 5 s instead of the built-in 10 s;
T2 proved it is redundant — the as-shipped kernel already self-reboots on panic
via `CONFIG_PANIC_TIMEOUT=10`, so rollback works with an unmodified cmdline.

## Common harness

Every software test uses the same snapshot / inject / restore frame. Run all
prep as root on the board over SSH; keep a serial console attached for the
U-Boot capture and for recovery.

### Safety rules

1. **Only ever modify the inactive slot.** Confirm the active slot first
   (`rauc status`); the active slot is the safety net and must stay good.
2. Never touch the shared `/boot` FIT.
3. Snapshot the env and back up the inactive slot's head before corrupting;
   restore both afterward.
4. If a test strands the board, the good active slot plus the `rauc_validate_slot`
   backstop recover it; worst case, set `BOOT_ORDER` / `BOOT_<slot>_LEFT` from the
   U-Boot prompt over serial.

### Snapshot + back up (before)

```bash
# active slot is A here; adjust the inactive device/name for a B-active board
mkdir -p /data/rollback-test && cd /data/rollback-test
fw_printenv > env-before.txt
# back up the inactive slot's superblock region so corruption is reversible
dd if=/dev/mmcblk0p3 of=p3-head-backup.bin bs=1M count=16 conv=fsync
```

### Restore + verify (after)

```bash
cd /data/rollback-test
dd if=p3-head-backup.bin of=/dev/mmcblk0p3 bs=1M conv=fsync   # restore B
fw_setenv EXTRA_KERNEL_ARGS '<original value from env-before.txt>'
# env must return to the pre-test snapshot:
diff <(grep -E '^(BOOT_ORDER|BOOT_A_LEFT|BOOT_B_LEFT|EXTRA_KERNEL_ARGS)=' env-before.txt | sort) \
     <(fw_printenv | grep -E '^(BOOT_ORDER|BOOT_A_LEFT|BOOT_B_LEFT|EXTRA_KERNEL_ARGS)=' | sort)
mount -o ro /dev/mmcblk0p3 /mnt && umount /mnt   # B mounts again
rauc status                                      # active slot good
rm -rf /data/rollback-test
```

## Procedures

### T1 — corrupt inactive slot → revert (reference run)

The witnessed path. Serves as the template for T2.

```bash
# after snapshot + backup:
fw_setenv EXTRA_KERNEL_ARGS '<original> panic=5'   # failed slot self-reboots
dd if=/dev/zero of=/dev/mmcblk0p3 bs=1M count=16 conv=fsync   # kill B's superblock
mount -o ro /dev/mmcblk0p3 /mnt 2>&1 || echo "B unmountable (intended)"
fw_setenv BOOT_ORDER "B A"      # simulate a freshly-activated bad update on B
fw_setenv BOOT_B_LEFT 3
fw_setenv BOOT_A_LEFT 3
reboot
```

Capture the serial console across the reboot. **Pass** requires all of:

- 3× `[RAUC] selected slot=B part=3 (root=/dev/mmcblk0p3)`, each followed by
  `Saving Environment to MMC ... OK` (counter persisted) then
  `Kernel panic - not syncing: VFS: Unable to mount root fs` and
  `Rebooting in 5 seconds`.
- After the third, U-Boot selects slot A and boots to a healthy userland.
- Post-boot: `rauc status` shows `Booted from: rootfs.0 (A)`, `BOOT_B_LEFT=0`,
  slot B `boot status: bad`.

### T2 — same, as-shipped cmdline (no `panic=`)

Identical to T1 but skip the `EXTRA_KERNEL_ARGS` edit. **Result (2026-07-08,
PASS)**: each corrupted-slot boot panicked at rootfs-mount and printed
`Rebooting in 10 seconds` — the kernel's compiled-in `CONFIG_PANIC_TIMEOUT=10`,
not a cmdline flag — then reset into U-Boot and consumed an attempt. After the
counter reached 0 the board reverted to A. Confirms the auto-revert works on an
unmodified image; `panic=` and the watchdog are not on the critical path for a
panicking slot.

### T3 — kill install mid-write

`rauc install` is only a client; the **`rauc.service` daemon** does the write, so
kill the daemon, not the CLI (killing the CLI leaves the write running).

```bash
setsid rauc install /home/devel/bundle.raucb >/tmp/i.log 2>&1 &   # writes inactive slot
# wait until the write to the target slot has begun, then:
#   journalctl -u rauc.service -f  → "writing data to device .../rootfsB"
systemctl kill -s SIGKILL rauc.service       # crash the updater mid-write
systemctl start rauc.service                 # let it come back to query
rauc status                                  # target still 'bad', active unchanged
reboot                                        # must come up on the active slot
```

**Result (2026-07-09, PASS)**: killed at 49% "Copying image to rootfs.1".
`BOOT_ORDER` stayed `A`, `BOOT_B_LEFT=0`, slot A stayed active/good, the reboot
booted A. The target slot was left `bad` and only partially written (not cleanly
mountable) — the correct outcome; RAUC never marks a half-written slot active.
The interrupted slot is recovered by a later full OTA, not by this test.

### T6 — bad post-install hook

Force `bundle-hooks.sh` post-install to `die`/`exit 1`, `make bundle`, install it.

**Gotcha (learned 2026-07-09):** the target slot must hold a **valid filesystem**
first. RAUC mounts the target during the update (verity/adaptive handling); if the
slot is corrupt (e.g. left bad by a prior T1/T3), the install aborts at
`failed to mount slot` *before* reaching the hook — a real abort, but not the hook
path. `mkfs.ext4 -F -L rootfsB <inactive-dev>` first, then install.

**Result (2026-07-09, PASS)**: with B clean, the install wrote B (~8.5 min ext4
write to eMMC), ran the post-install hook, logged
`[bundle-hook][ERROR] T6 synthetic post-install hook failure`, and RAUC reported
`Installation failed: … failed to run slot hook: Child process exited with code 1`.
Active stayed A, `BOOT_ORDER=A`, B never marked active. Revert the recipe injection
(`git checkout` / re-edit) and rebuild a clean bundle afterward.

### T7 — both slots exhausted (backstop)

```bash
fw_setenv BOOT_A_LEFT 0
fw_setenv BOOT_B_LEFT 0
reboot
```

No corruption — the rootfs is fine, only the counters are zeroed. **Pass**: the
console shows `[RAUC] no bootable slot, resetting counters`, the board resets
once, then boots normally with counters back at 3. Safe demonstration of the
`rauc_validate_slot` path.

### T8 — runtime failure after mark-good (documents the gap)

```bash
systemctl disable --now <critical-unit>   # break the workload, not the boot
reboot
```

**Expected**: the board boots the **same** slot — no revert — because
`rauc-mark-good` already reset the counter early in the previous boot. This is
the documented limitation: rollback triggers on boot failure, not workload
health. Closing it means a health-gated confirm-boot service that only
mark-goods after the workload reports healthy (the deferred
`virtual-ota-confirm-boot`, `docs/adr/0005-image-class-ota-backend.md`).

## Result log

| ID | Date | Result | Evidence |
|----|------|--------|----------|
| T1 | 2026-07-08 | **PASS** | serial capture: 3× slot-B panic → revert to A; `BOOT_B_LEFT` 3→0; booted A good |
| T2 | 2026-07-08 | **PASS** | as-shipped cmdline: panic → `Rebooting in 10 seconds` (`CONFIG_PANIC_TIMEOUT=10`) ×3 → revert to A; no `panic=`/watchdog needed |
| T3 | 2026-07-09 | **PASS** | SIGKILL'd rauc daemon at 49% "Copying image to rootfs.1"; `BOOT_ORDER=A`/`BOOT_B_LEFT=0` unchanged, A stayed active/good, reboot booted A; B left bad/partial (expected) |
| T4 | — | not run (needs bench power control) | |
| T5 | — | not run (needs bench power control) | |
| T6 | 2026-07-09 | **PASS** | bundle rebuilt with post-install hook forced to `exit 1`; install wrote B then hook logged `T6 synthetic post-install hook failure` → `Installation failed: failed to run slot hook`; B never marked active, active stayed A |
| T7 | 2026-07-08 | **PASS** | zeroed both counters → `[RAUC] no bootable slot, resetting counters` → self-heal to A; env re-normalized by mark-good |
| T8 | 2026-07-08 | **PASS** (confirms gap) | synthetic unit failed (exit 1), `rauc-mark-good` still ran, no revert — rollback is not health-gated |

## Field observation — kernel drift (2026-07-09)

Not an injected test, but a real failure surfaced while re-provisioning slot B
with a freshly-built rootfs-only bundle: the install succeeded and B was marked
active, but B **failed to boot and auto-rolled-back to A**. Serial capture (raw
`cat /dev/ttyUSB1` to file — mcp-serial read windows splice across retries)
showed B panicking at t≈10 s in `systemd-modules-load`:
`resolve_symbol` → `kernel BUG at lib/list_debug.c:29` → `Kernel panic`, loading
the out-of-tree modules (`vspm`/`mmngr`/`drpai`/`mmngrbuf`/`u_dma_buf`). The
modules' version string matched (vermagic passed) but they were built against a
different kernel than the shared `/boot` FIT → symbol-resolution corruption. This
is the rootfs-only-bundle + shared-`/boot` coupling documented in
[`ota-updates.md`](ota-updates.md#kernel-coupling-the-main-gotcha); the rollback
correctly protected the device. `pstore: writing error (-28)` (ENOSPC) is why the
crash never persisted to journal/pstore.

## References

- [`ota-updates.md`](ota-updates.md) — the OTA + rollback reference this plan backs.
- `docs/security/CRA-CONTROLS.md` — 8.a availability control this validates.
- `docs/adr/0005-image-class-ota-backend.md` — `virtual-ota-confirm-boot` (health-gated mark-good) deferral.
- `docs/security/uboot-hardening.md` — U-Boot env layout, bootcount variables.
- `meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults` — the slot-selection state machine.
- `meta-edge-bsp/recipes-ota/rauc/files/system.conf` — `boot-attempts`, slot map.

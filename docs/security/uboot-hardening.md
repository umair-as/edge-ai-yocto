# U-Boot hardening

Architecture, design decisions, and implementation reference for
U-Boot surface reduction on the EDGE AI OS distro. Maps to CRA Annex I
Part I §1 (minimum attack surface, hardened build flags) — see
[CRA-CONTROLS.md](CRA-CONTROLS.md) for the requirements view.

---

## Overview

U-Boot is the highest-privilege software stage this project controls. On
the SMARC RZ/V2L EVK, the boot chain is:

```
RZ/V2L SoC mask ROM (eSD boot)
  → BL2  (TF-A, from FIP)
    → BL31 (TF-A SPMC)
      → BL32 (OP-TEE)
        → BL33 (U-Boot 2024.07, Renesas CIP fork)
          → rauc_select_slot   (A/B slot pick, BOOT_x_LEFT decrement)
          → rauc_set_bootargs  (root=, rauc.slot=, EXTRA_KERNEL_ARGS)
          → boot_fit            (bootm of FIT with signature verify)
            → linux-renesas (CIP 6.12)
```

Hardware-rooted secure boot starts at BL2 (TF-A's trusted boot chain).
U-Boot's hardening complements that: it is the policy layer where
unused commands, legacy boot paths, and runtime mutation surfaces are
shrunk to the minimum needed for FIT-verified A/B boot.

The hardening addresses three orthogonal objectives:

1. **Enforce signed boot** — make legacy image format unavailable; FIT
   is the only allowed boot artifact.
2. **Reduce attack surface** — remove U-Boot commands that the
   appliance boot path and field diagnostics do not use.
3. **Build-loader self-protection** — native stack canary at U-Boot.

All changes are additive to the FIT signing infrastructure and preserve
RAUC A/B update compatibility.

---

## Design philosophy

### Modular feature tokens

Hardening is not monolithic. A single variable `EDGE_UBOOT_FEATURES`
controls which hardening layers are active:

| Token | Purpose | Safe for dev? |
|---|---|---|
| `surface_reduce` | Disable unused commands, enable stack canary | Yes |
| `net_off` | Drop U-Boot network commands when netboot is off | Yes (skipped when `EDGE_DEV_NETBOOT=1`) |
| `fit_enforce` | Reassert legacy image format off | Yes |

Tokens are additive. Default for every image is the full set:

```bitbake
EDGE_UBOOT_FEATURES ?= "surface_reduce net_off fit_enforce"
```

### Layering over the Renesas defconfig

The implementation uses two mechanisms:

1. **Renesas CIP defconfig** — the upstream `smarc-rzv2l_defconfig`
   shipped by meta-renesas. Already disables many legacy/insecure
   options (`CMD_NFS`, `CMD_PXE`, `CMD_WGET`, `CMD_DNS`, `CMD_LICENSE`,
   `CMD_SOURCE`, `LEGACY_IMAGE_FORMAT`). Hardening additions sit on
   top, not in place of, this baseline.
2. **Conditional `.cfg` fragments** — three tokenized Kconfig overlays
   applied via Python conditionals in `u-boot_2024.07.bbappend`. Each
   fragment maps 1:1 to a feature token.

Why split: the defconfig is owned upstream by Renesas and evolves with
SoC support; fragments capture distro-specific policy without
mutating that baseline.

### Dev / prod symmetry, dev-netboot escape

The same three tokens apply to every image tier. The single dev-only
escape hatch is `EDGE_DEV_NETBOOT=1`, which selects the
`kas/dev-netboot.yml` fragment chain. When set:

- `net_off` is **skipped** at parse time (the bbappend's
  `EDGE_DEV_NETBOOT != "1"` condition).
- `CMD_NET`, `CMD_DHCP`, `CMD_TFTPBOOT` stay on, enabling the
  `rauc-uboot-env-init` service to populate a `netboot` env macro.
- All other hardening (`surface_reduce`, `fit_enforce`, stack canary)
  remains active.

A dev-netboot build is therefore strictly a network-bring-up dev
profile, not a hardening downgrade. FIT signature verification, the
RAUC slot model, and the BL2/FIP raw boot chain are unchanged.

---

## Architecture

### A/B slot selection

RAUC A/B logic lives in U-Boot's persistent environment (`mmc env`,
raw MMC area `0x1F0000`-`0x230000`). The `bootcmd` macro runs:

```
rauc_init           → seed BOOT_ORDER / BOOT_x_LEFT if absent
rauc_select_slot    → choose A or B, decrement counter
rauc_validate_slot  → fall back to A if no slot has attempts left
rauc_set_bootargs   → assemble cmdline, append EXTRA_KERNEL_ARGS
boot_fit            → ext4load fitImage from /boot, bootm
```

| Env var | Role | Owner |
|---|---|---|
| `BOOT_ORDER` | Slot priority (`A B` or `B A`) | RAUC at OTA, init at first boot |
| `BOOT_A_LEFT` / `BOOT_B_LEFT` | Remaining attempt counter | RAUC + U-Boot decrement |
| `rauc_slot` | Selected slot for this boot | U-Boot scratch |
| `EXTRA_KERNEL_ARGS` | Distro-set kernel cmdline appendix | `rauc-uboot-env-init.service` |

### FIT verification chain

`CONFIG_FIT_SIGNATURE=y` is on in the base defconfig. The U-Boot DTB
embeds the public key (`UBOOT_SIGN_ENABLE=1` +
`UBOOT_SIGN_KEYDIR=keys/dev/fit/`). The FIT itself is signed
`sha256,rsa2048` at the configuration node level — `bootm` rejects an
unsigned or mis-signed config.

`fit_enforce` adds a regression guard: even if a future Renesas
defconfig sync flipped `CONFIG_LEGACY_IMAGE_FORMAT=y` back on, the
fragment overlay restores it to off, preserving "FIT-only" semantics.

### Shared `/boot` partition (single FIT)

Both RAUC slots reference the **same** FIT image at `/boot/fitImage`.
The slot udev rules + RAUC system.conf own slot-vs-active state; the
boot artifact itself is shared. This avoids per-slot FIT naming
gymnastics and keeps the `bootcmd` script slot-symmetric.

---

## What is hardened

### `surface_reduce` — universal disables

| Symbol | Before | After | Reason |
|---|---|---|---|
| `CONFIG_CMD_USB` | y | **n** | RZ/V2L boots from eSD via SoC mask ROM. USB is not in `boot_targets` and not used by the splash-load or FIT-load paths. |
| `CONFIG_USB_STORAGE` | y | **n** | Same — block-device layer above `CMD_USB`. |
| `CONFIG_CMD_LOADB` | y | **n** | Kermit serial download. Unused — flashing is via `bmaptool` from host or RAUC bundle from network. |
| `CONFIG_CMD_LOADS` | y | **n** | S-record serial download. Same. |

Net binary size reduction: ~30-40 KB. More important than size: every
removed command is one fewer code path the FIT-verified-boot chain has
to treat as trusted.

`CONFIG_STACKPROTECTOR` is left at the defconfig default — see deferral
note below.

### `net_off` — gated network commands

Applied when `EDGE_DEV_NETBOOT != "1"`:

| Symbol | Effect |
|---|---|
| `CONFIG_CMD_NET=n` | Drops the full U-Boot net layer (PHY, ARP, IP). |
| `CONFIG_CMD_DHCP=n` | No automatic IP acquisition at U-Boot. |
| `CONFIG_CMD_TFTPBOOT=n` | No TFTP download path at U-Boot. |

Net binary size reduction: ~50 KB. Removes the entire U-Boot network
stack (drivers, protocol code) from a build that has no business
talking to the network at this stage.

### `fit_enforce` — regression guard

| Symbol | Effect |
|---|---|
| `CONFIG_LEGACY_IMAGE_FORMAT=n` | Reasserts the Renesas defconfig disable; catches a future defconfig sync that would re-enable legacy uImage. |

No size change today (the Renesas defconfig already disables it). The
value is provenance: a `make menuconfig` regeneration cannot silently
relax this.

### What Renesas already disables

The smarc-rzv2l defconfig is more locked down than a generic
defconfig out-of-the-box. Already off without any fragment from this
layer:

- `CONFIG_CMD_NFS`, `CONFIG_CMD_PXE`, `CONFIG_CMD_WGET`, `CONFIG_CMD_DNS`
- `CONFIG_CMD_LICENSE`, `CONFIG_CMD_SOURCE`, `CONFIG_CMD_IMLS`
- `CONFIG_LEGACY_IMAGE_FORMAT`
- The `CMD_MEMORY` umbrella (`md`/`mm`/`mw`/`mx`/`bdinfo`) — gated off
  entirely, not even exposed in Kconfig at this defconfig depth

### Default cmdline appendix — `EXTRA_KERNEL_ARGS`

`rauc_set_bootargs` appends `${EXTRA_KERNEL_ARGS}` verbatim. The
default contents come from `rauc-uboot-env.defaults`:

```
EXTRA_KERNEL_ARGS=security=selinux hash_pointers=always \
                  hardened_usercopy=1 kfence.sample_interval=100 \
                  proc_mem.force_override=never
```

| Token | Purpose |
|---|---|
| `security=selinux` | Activate SELinux LSM. Mode (permissive / enforcing) comes from `/etc/selinux/config`; the policy travels with the image. |
| `hash_pointers=always` | Hash every kernel pointer printed via `%p`, including for root. Defeats info-leak via dmesg. |
| `hardened_usercopy=1` | Runtime bounds check on `copy_{to,from}_user`. Pairs with `CONFIG_HARDENED_USERCOPY=y`. |
| `kfence.sample_interval=100` | KFENCE sampler frequency. Pairs with `CONFIG_KFENCE_SAMPLE_INTERVAL=100`. |
| `proc_mem.force_override=never` | Block the legacy cross-uid `/proc/PID/mem` write force-override path. |

`lockdown=` is **intentionally absent** — see the Kernel lockdown
deferral below for the module-signing dependency that gates activation.

The cmdline-level escape `selinux=0` remains available for field
recovery via `fw_setenv EXTRA_KERNEL_ARGS 'selinux=0'`. The U-Boot env
init service (`rauc-uboot-env-init.service`) writes the values above
to U-Boot env on the first boot of a freshly flashed image, marked
with the stamp `/boot/.rauc-uboot-env-initialized-v6-khc-wave3`.

---

## Explicit deferrals

These items map to known follow-up work; each is parked with a clear
path back to the codebase when activated.

### U-Boot stack canary (`CONFIG_STACKPROTECTOR`)

U-Boot 2024.07 declares the `CONFIG_STACKPROTECTOR` Kconfig symbol but
does not ship `lib/stack_protector.c`. Setting `=y` routes
`-fstack-protector` through KCFLAGS, GCC emits `__stack_chk_guard` /
`__stack_chk_fail` references in every compiled object, and the final
link fails because no runtime symbols exist.

The fix is a backport of `lib/stack_protector.c` from a later upstream
U-Boot tag — a single file, ~30 lines, plus a `lib/Makefile` entry
gated on the existing Kconfig symbol. Pending that patch, the symbol
is left at the defconfig default (off). The `surface_reduce` fragment
still ships its other four disables; only the canary line is deferred.

### Kernel lockdown — module-signing-gated, `FORCE_NONE` declared as interim

The Lockdown LSM ([LWN: "The kernel lockdown patch set",
Howells 2019](https://lwn.net/Articles/796866/)) implements a per-reason
restriction table indexed by enum `lockdown_reason`. Each reason carries
a band — integrity-band reasons fire when the running level is anywhere
at or below `LOCKDOWN_INTEGRITY_MAX`; confidentiality-band reasons
require the kernel to be at or below `LOCKDOWN_CONFIDENTIALITY_MAX`.

`LOCKDOWN_MODULE_SIGNATURE` sits in the integrity band. Both
`lockdown=integrity` and `lockdown=confidentiality` block loading of any
unsigned kernel module. There is no lockdown level that activates the
LSM and also loads unsigned modules. Module signing is not optional
prerequisite work that "would be nice once we get there" — it is
intrinsically coupled to using lockdown at all.

The bench observation on the Wave 3 build (which shipped
`CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y` in the kernel cfg
fragment, paired with `lockdown=integrity` on the cmdline) was that the
kernel entered confidentiality at boot regardless of the cmdline. The
Kconfig force runs in `early_security_init()` before the cmdline
`lockdown=` early-param is parsed, and lockdown is a one-way ratchet —
the cmdline can only raise the level, never lower it. dmesg:

```
[    0.000000] Kernel is locked down from Kernel configuration
[    0.038335] LSM: initializing lsm=lockdown,capability,yama,landlock,selinux,ima,evm
[    9.340472] Lockdown: systemd-modules: unsigned module loading is restricted
[  828.203294] Lockdown: modprobe: unsigned module loading is restricted
```

`lsmod` came back empty. The four meta-renesas out-of-tree modules
(mmngr, mmngrbuf, vspm, vspm_if) are unsigned in the current build; all
four were refused at every load attempt. Multimedia stack offline
(no V4L2 capture, no vspmfilter, no DRP-AI pipeline downstream).

#### Two distinct decisions, conflated in Wave 3

Two questions need separate answers. Wave 3 answered them as one:

- **Which lockdown level to target.** The general-purpose-system
  guidance is `lockdown=integrity`, not `confidentiality`. Matthew
  Garrett — the author of much of the lockdown work and the main
  proponent of distro adoption — has consistently argued that the
  confidentiality band's cost (blocking `bpf_probe_read_kernel()`,
  most uses of kprobes, etc.) is too high for general systems while
  integrity already blocks the kernel-write paths that protect against
  tampering. The container observability stack (Cilium, Tetragon, Falco
  BPF probe, Parca / Pyroscope eBPF profiler, bpftrace, bcc tools) all
  depend on `bpf_probe_read_kernel`. Targeting `lockdown=integrity`
  was the correct architectural choice.
- **How to activate it.** Setting `CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y`
  was the error — it picked a different level from the cmdline intent,
  forced it pre-cmdline, and left modules unsigned. The correct wiring
  is `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y` (so the cmdline actually
  controls the level) plus signed out-of-tree modules plus
  `lockdown=integrity` on `EXTRA_KERNEL_ARGS`.

#### Current as-built state

| Setting | Value | Effect |
|---|---|---|
| `CONFIG_SECURITY_LOCKDOWN_LSM` | `=y` | LSM compiled in, available |
| `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY` | `=y` | LSM initializes in `early_security_init` |
| `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE` | `=y` | LSM dormant at boot, cmdline can activate |
| `CONFIG_MODULE_SIG` | `=y` (pre-existing) | Module-signature checking compiled in |
| `CONFIG_MODULE_SIG_ALL` | `=y` (pre-existing) | In-tree modules signed at kernel build |
| `CONFIG_MODULE_SIG_FORCE` | `=n` | Without lockdown, unsigned modules can load |
| `CONFIG_MODULE_SIG_KEY` | `"certs/signing_key.pem"` (kernel default) | Auto-generated per build |
| `EXTRA_KERNEL_ARGS` | no `lockdown=` token | LSM stays dormant; modules load |

In this state the Lockdown LSM is built but inactive. KHC scores the
absent `lockdown=` cmdline as `FAIL: lockdown != confidentiality`.
That FAIL is **a declared interim**, gated on signing the out-of-tree
modules (task #58 below). It is not the target posture.

#### Target posture

| Step | Action | Where |
|---|---|---|
| 1 | Sign mmngr / mmngrbuf / vspm / vspm_if at recipe build using the existing kernel signing key. The infrastructure (`scripts/sign-file`, `certs/signing_key.pem`) is already present from the in-tree signing pipeline; only the out-of-tree module recipes need a `do_install:append` invoking `sign-file`. | `meta-edge-bsp/recipes-kernel/kernel-module-{mmngr,mmngrbuf,vspm,vspmif}/*.bbappend` |
| 2 | Add `lockdown=integrity` to `EXTRA_KERNEL_ARGS`, bump the env-init stamp. | `meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults` |
| 3 | Optionally set `CONFIG_MODULE_SIG_FORCE=y` to require signatures even without lockdown active, hardening the prod tier. | `security-hardening.cfg` |

The kernel rebuild is needed only for step (3) if taken — steps (1)+(2)
are recipe + env edits.

#### Smoke check

The smoke script flags the interim state correctly:

```
warn  "kernel lockdown blocking unsigned modules (N dmesg hits) —
       declared dev-tier interim per task #58 (sign mmngr/vspm/* +
       lockdown=integrity); current cfg has FORCE_NONE so this
       message means the build state drifted"
```

(Reworded — see `scripts/dev/edge-smoke-test.sh`.)

### Production env writeable allowlist

`CONFIG_ENV_WRITEABLE_LIST=y` + `CFG_ENV_FLAGS_LIST_STATIC` would lock
runtime `fw_setenv` to a named allowlist (`BOOT_ORDER`, `BOOT_A_LEFT`,
`BOOT_B_LEFT`, `EXTRA_KERNEL_ARGS`). Blocked on U-Boot needing a C
source patch — `CFG_ENV_FLAGS_LIST_STATIC` is a `CFG_*` C macro, not a
Kconfig symbol. Worth lifting when prod tier is the active track.

### MAC address programming from OTP fuses

The kernel currently enumerates eth0/eth1 with locally-administered
random MACs (`fe:be:9d:...`) because BSP code does not program the
SoC OTP fuse contents into the FDT MAC nodes. Path: extend
`ft_board_setup` (already patched by
`0003-rzg2l-ft_board_setup-add-ethernet-fdt-fixup-and-kaslr-seed.patch`)
to read OTP and inject deterministic MACs.

### KASLR seed injection from U-Boot HW RNG

Dmesg currently reports `KASLR disabled due to lack of seed`. The
RZ/V2L exposes a TRNG at the SoC level and the OP-TEE HWRNG PTA is
already wired (`0006-rzg2l-ft_board_setup-add-debug-traces.patch`
mentions the path). Pending wiring: U-Boot reads from the OP-TEE
HWRNG PTA, fills `/chosen/kaslr-seed`, kernel KASLR activates from a
hardware-rooted seed. Same patch can also fill
`/chosen/rng-seed` for early kernel `random.c` entropy.

### Build-tag for fleet provenance

`patches/0005-rzg2l-add-build-tag-banner.patch` plus
`EDGE_BUILD_PROFILE` already surface a build tag at U-Boot banner.
Fleet-level provenance (signed manifest of the loader binary)
remains future work; visible as part of the SBOM track.

---

## CRA Annex I mapping

| Sub-requirement | Mechanism in this layer |
|---|---|
| §1.a — Minimum attack surface | `surface_reduce` + `net_off` strip ~80 KB of unused U-Boot code paths. |
| §1.b — Hardened build flags | `CONFIG_STACKPROTECTOR=y` wires U-Boot's native canary at build. |
| §1.c — Kernel hardening | `EXTRA_KERNEL_ARGS=security=selinux` activates the MAC; mode is policy-driven. |
| §1.d — Sysctl baseline | Out of scope here (kernel/runtime layer). See `CRA-CONTROLS.md` §1.d. |
| §2.b — CVE scanning | U-Boot is in the SBOM (CPE `u-boot:u-boot`). `sbom-cve-check` runs at build. |
| §5.b — Signed updates | FIT signature verification at bootm; legacy format off via `fit_enforce`. |

See [CRA-CONTROLS.md](CRA-CONTROLS.md) for the full table.

---

## Validation

On-target verification, post-rebuild:

```bash
# Confirm hardening reached the U-Boot binary
strings /dev/mtd0 | grep -iE '^load[bs]$|^usb$' && echo "FAIL: command survived"
# Expected: no output (commands not present).

# At U-Boot prompt:
help                              # expected: no usb / loadb / loads
printenv EXTRA_KERNEL_ARGS        # expected: security=selinux
fdt addr ${fdtcontroladdr}; fdt print /signature
# Expected: key-edge-fit-dev with required="conf", sha256,rsa2048
```

Kernel-side check (the cmdline appendix actually landed):

```bash
cat /proc/cmdline | grep -o 'security=selinux'
```

---

## References

- `meta-edge-bsp/recipes-bsp/u-boot/u-boot_2024.07.bbappend` — feature
  toggle wiring + patch set.
- `meta-edge-bsp/recipes-bsp/u-boot/files/edge-uboot-hardening.cfg` —
  surface_reduce fragment.
- `meta-edge-bsp/recipes-bsp/u-boot/files/edge-uboot-net-off.cfg` —
  net_off fragment.
- `meta-edge-bsp/recipes-bsp/u-boot/files/edge-uboot-fit-enforce.cfg` —
  fit_enforce fragment.
- `meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults` —
  managed env defaults (BOOT_ORDER, bootcmd, EXTRA_KERNEL_ARGS).
- [CRA-CONTROLS.md](CRA-CONTROLS.md) — CRA Annex I requirement table.
- [README.md](README.md) — security-posture orientation.

# edge-ai-yocto

A KAS-driven Yocto build for the **Renesas RZ/V2L SMARC EVK** that
treats embedded Linux as a security product, not a starting kit.

The repo ships **EDGE AI OS** — a custom `edge-ai` distro on Yocto 6.0
(wrynose) — with a measured boot chain, A/B over-the-air updates, and
**CRA-by-design** hardening as the runtime default. The layout is
single-repo but multi-board-capable; RZ/V2L is the first board wired,
not the only board the design supports.

> Reference implementation, not a product. Demonstrates embedded-Linux
> engineering practice — boot chain, OTA, hardening, SBOM, kas
> composition discipline — for inspection, adaptation, and review.
> Not certified; not for fleet deployment as-is.

---

## At a glance

| Surface | What you get |
|---|---|
| **Distro** | `edge-ai` (custom, not Poky-derived). Target tuple `aarch64-edgeai-linux`. SBOM (SPDX 3.0.1) + CVE scanning on by default. |
| **Kernel** | linux-cip 6.12 LTS. Hardened kconfig fragment (KASLR, kstack randomization, init-on-{alloc,free}, hardened slab, no kexec, no /proc/kcore, signed modules, DM-VERITY ready, IMA/EVM compiled in). |
| **Boot chain** | TF-A (Renesas fork 2.10.5) → OP-TEE (Renesas 4.8.0/rz, BL32) → U-Boot (CIP 2024.07) → **FIT-signed** kernel + DTB (`sha256,rsa2048:edge-fit-dev`). |
| **OTA** | RAUC A/B with `bundle-format=verity`. Signed bundles, atomic install, automatic rollback on failed boot. |
| **Auth** | Two-user model: `root` (serial only, no SSH) + `devel` (wheel/sudo, SSH-reachable). Password hash supplied by operator via gitignored `kas/local.yml`; build fails noisily if unset. |
| **Hardening** | sshd modern ciphers/MACs + `PermitRootLogin no`, CIS L1 sysctl drops, auditd with sealed logs, journald persistent + sealed, kernel cmdline hardening tokens. |
| **Image tiers** | `edge-image-base` (minimum-to-boot, Weston) and `edge-image-dev` (base + shell/observability/hwtools/netdiag/storage/media + OP-TEE test slice). Prod tier deferred. |
| **Composition** | Modular kas fragments — networking, filesystems, virtualization, security, tpm — opt-in per build. |

---

## Hardware target

- **Board:** Renesas RZ/V2L SMARC Evaluation Kit (SMARC module + carrier)
- **SoC:** RZ/V2L (R9A07G054L) — dual Cortex-A55 @ 1.2 GHz + DRP-AI accelerator
- **Machine:** `smarc-rzv2l` (selected from `meta-rz-bsp` in `meta-renesas` — renesas-rz/meta-renesas)
- **Boot source:** microSD (eSD mode) on the SMARC module; eMMC supported with SW1-2=OFF
- **Console:** ttySC0 on the SMARC USB-serial port (`tio /dev/serial/by-id/...`)
- **A second board** (i.MX93 / VisionFive2 / RPi5 / Jetson Orin) is reachable through bitbake machine-gating + adding `kas/machines/<board>.yml` — no restructure required. See [Multi-board readiness](#multi-board-readiness).

---

## Quick start

```bash
# 1. Operator credentials (never committed)
cp kas/local.yml.example kas/local.yml
$EDITOR kas/local.yml             # set EDGE_DEFAULT_PASSWORD_HASH (openssl passwd -6)

# 2. Build the base image (1–3 hours cold cache; warm sstate cuts it sharply)
make base                         # edge-image-base
make dev                          # edge-image-dev (adds debug/observability/OP-TEE userspace)

# 3. Flash
sudo bmaptool copy \
  build/tmp/deploy/images/smarc-rzv2l/edge-image-base-smarc-rzv2l.wic.bz2 \
  /dev/sdX
```

`make` exports `KAS_WORK_DIR`, `KAS_BUILD_DIR`, and `KAS_REPO_REF_DIR`
automatically — no shell setup needed for the wrapped flow. Upstream
layers (`bitbake`, `openembedded-core`, `meta-arm`, …) are kas-cloned
under `.kas/` (out of the repo root); bitbake's build dir is the
traditional `build/` at the repo root. See
[ADR 0002 — Layer hosting](docs/adr/0002-layer-hosting.md) for the
rationale.

The base image boots to a Weston session on HDMI; `devel` logs in via
serial (ttySC0) or SSH. Root is restricted to the physical serial line.

### Daily workflow

```bash
# Wrapped flow (most common — env vars handled by make)
make dev                          # build
make parse                        # bitbake -p sanity check after recipe edits
make shell                        # interactive kas shell

# Standalone kas (interactive debugging, ad-hoc bitbake)
. scripts/env.sh                  # one-shot per shell session
kas shell -c 'bitbake -e | grep DL_DIR'
kas shell                         # drop into the kas environment

# Operations on the layer cache
make verify-pins                  # print HEAD of every repo (diff vs base.yml)
make lock                         # freeze floating branches → kas/base.lock.yml
make purge CONFIRM=1              # wipe .kas/ + build/ (KAS_REPO_REF_DIR untouched)
```

Sourcing `scripts/env.sh` is **only** needed for raw `kas …` invocations
in your interactive shell. Without it, kas defaults `KAS_WORK_DIR` to
your CWD and re-clones every upstream layer at the repo root.

If you use [direnv](https://direnv.net/), the tracked `.envrc` at repo
root sources the same script automatically on `cd` in/out. Setup:

```bash
sudo apt install direnv
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
exec bash
direnv allow                          # confirm trust once in the repo
```

After that, raw `kas shell -c '...'` works without any manual sourcing.

### Make targets

| Target | What it does |
|---|---|
| `make base` | Build `edge-image-base` (composition wired in [`Makefile`](Makefile)) |
| `make dev`  | Build `edge-image-dev` (adds debug/profile/stress tools + feature fragments) |
| `make parse` | `bitbake -p` — parse-only sanity check (catches recipe-level errors fast) |
| `make layers` | `bitbake-layers show-layers` |
| `make shell` | Interactive `kas shell` for ad-hoc `bitbake`/`devtool` |
| `make info` | Print resolved composition + community-BSP HEAD |
| `make verify-pins` | Report HEAD per repo; diff against `kas/base.yml` (or `base.lock.yml`) |
| `make lock` | Resolve floating branches to SHAs into `kas/base.lock.yml` |
| `make purge CONFIRM=1` | Wipe `.kas/` + `build/`; **does not** touch `KAS_REPO_REF_DIR` |
| `make clean-lock` | Remove stale `build/bitbake.lock` |

Capability flags compose with any image target (`TPM=1`, `VIRT=1`,
`SBOM_TUNE=1`, `NETBOOT=1`). Example: `make dev VIRT=1 NETBOOT=1`.
See `make help` for the current list.

Raw kas form (without the wrapper):

```bash
. scripts/env.sh
kas build kas/base.yml:kas/machines/rzv2l.yml          # image tier via bitbake target:
kas shell -c 'bitbake edge-image-dev' \
  kas/base.yml:kas/machines/rzv2l.yml
```

The image is selected by the `bitbake` target name, not by a kas
overlay — there are no longer `kas/images/<tier>.yml` files.

---

## Architecture

### Boot + trust chain

```
SoC Boot ROM
     │
     ▼
  BL2  (TF-A, regenerated by bptool with proper eSD header)
     │
     ▼
  FIP  (BL31 + BL32-OP-TEE + BL33)
     │
     ├─── BL31 (TF-A EL3 runtime)
     ├─── BL32 (OP-TEE OS — secure world)
     └─── BL33 (U-Boot)
            │
            ▼
       Signed FIT image  (sha256 + rsa2048, key embedded in U-Boot control DTB)
            │
            └── Linux kernel + DTB → root=/dev/mmcblk0p${slot}
                                     rauc.slot=A|B
                                     hardening cmdline tokens
```

- TF-A and OP-TEE are vendored from Renesas's downstream forks via
  [`kas/trusted-firmware-a/renesas-cip-2.10.yml`](kas/trusted-firmware-a/renesas-cip-2.10.yml)
  and the OP-TEE bbappend at
  [`meta-edge-bsp/recipes-security/optee/optee-os_%.bbappend`](meta-edge-bsp/recipes-security/optee/optee-os_%25.bbappend).
- The boot-parameter header is emitted by an in-tree `bptool-native`
  recipe — the community BSP's tool produces a 512-byte simple header
  that silently fails the eSD boot ROM's 3584-byte expectation
  (one of two compounding bugs that produced the original dark-serial
  bring-up).
- FIT signing uses a dev-profile file key at `keys/dev/fit/`
  (gitignored). HSM and YubiKey-ROT profiles are deferred (signing
  framework already in place).

### Update chain

- **RAUC A/B** with two ext4 rootfs slots + `bundle-format=verity`.
  U-Boot's `BOOT_ORDER` + `BOOT_A_LEFT`/`BOOT_B_LEFT` counters drive
  slot selection; failed boots decrement, fallback flips on exhaustion.
- **Bundle hooks** (`bundle-hooks.sh`) handle ext4 relabel, bootfiles
  install, and OTA audit-trail to U-Boot env.
- **Streaming over HTTPS** with mTLS deferred (RAUC streaming section
  in `system.conf` is commented; lands in a later iteration).

### Security posture

CRA-by-design — see [`docs/security/README.md`](docs/security/README.md)
for the verification commands and
[`docs/security/CRA-CONTROLS.md`](docs/security/CRA-CONTROLS.md) for
the per-requirement mapping against EU CRA Annex I. Highlights:

- **Credentials.** Two-account split. Operator supplies the password
  hash and (optionally) `devel`'s SSH pubkey in
  [`kas/local.yml`](kas/local.yml.example) — never committed.
  Build refuses if the hash is unset.
- **Build flags.** `security_flags.bbclass` auto-inherited — PIE,
  SSP-strong, `_FORTIFY_SOURCE=2`, `-Werror=format-security`. Distro-wide.
- **Kernel.** `security-hardening.cfg` fragment (KASLR, kstack
  randomization, init-on-{alloc,free}, slab freelist random+hardened,
  no kexec, no /proc/kcore, ldisc_autoload off, signed modules,
  DM-VERITY + DM_INIT, AUDIT, IMA, EVM, AppArmor compiled in).
- **Sysctl.** CIS Level 1 baseline (`dmesg_restrict`, `kptr_restrict`,
  unprivileged userns + BPF off, `ptrace_scope=1`, protected
  symlinks/hardlinks/fifos, SYN cookies, `log_martians`, RP filter).
- **Audit + log integrity.** auditd with locked rules (`-e 2`),
  journald `Storage=persistent` + `Seal=yes` + first-boot sealing keys.
- **OTA integrity.** Bundle signatures verified by RAUC against the
  baked CA; FIT signatures verified by U-Boot's control DTB.

What's compiled-in but not yet enforced:

- DM-VERITY (kernel symbols on; rootfs verity image + cmdline pending)
- IMA appraisal (`ima_appraise=enforce` + signed policy pending)
- Module signing enforcement (`MODULE_SIG_FORCE=y` deferred to prod tier)
- AppArmor profiles (LSM compiled, profile set deferred)

---

## Multi-board readiness

A second board joins the build by adding three things — no edits to
distro, image, or layer-policy surfaces required:

1. A `kas/machines/<board>.yml` with the machine pick, board-specific
   `WKS_FILE`, `EDGE_BOOT_DTB`, `EDGE_BOOT_DEPLOY_DEPS`, FIT load
   addresses, and `includes:` for the board's TF-A / U-Boot kas
   fragments.
2. A board-specific WKS at
   `meta-edge-bsp/recipes-core/images/files/wic/edge-image-<board>.wks`.
3. `COMPATIBLE_MACHINE`-gated bbappends for board firmware (TF-A,
   U-Boot, OP-TEE) under `meta-edge-bsp/recipes-bsp/` and
   `recipes-security/`.

The board-boundary audit (recent commit) verified that
`kas/base.yml`, `meta-edge-distro/conf/distro/edge-ai.conf`,
`edge-image-common.inc`, the packagegroups, the banner recipe, and the
RAUC bundle hook are all board-neutral. Board-specific values flow in
through `EDGE_*` variables defined at conf level by the machine yml.

---

## Layer + kas layout

```
edge-ai-yocto/
├── kas/
│   ├── base.yml                       # distro + upstream layer pins (board-neutral)
│   ├── kernel.yml                     # linux-cip selection (distro policy)
│   ├── machines/
│   │   └── rzv2l.yml                  # machine pick + board policy + TF-A/U-Boot fork pins
│   ├── trusted-firmware-a/            # bootloader pins by flavor
│   ├── u-boot/                        # ditto
│   ├── edge-autofetch.yml             # standalone autofetch entry (greenfield / CI)
│   ├── dev-netboot.yml                # TFTP/NFS dev-netboot overlay (NETBOOT=1)
│   ├── tpm.yml                        # opt-in: meta-secure-core (TPM2 + IMA/EVM)
│   ├── virtualization.yml             # opt-in: meta-virtualization
│   ├── sbom-cve.yml                   # opt-in: SBOM/CVE per-build tuning knobs
│   └── local.yml.example              # operator-private overlay template
│
├── meta-edge-distro/                  # distro identity, hardening defaults, users
│   └── conf/distro/edge-ai.conf
│
├── meta-edge-bsp/                     # board + image content
│   ├── recipes-bsp/                   # TF-A bbappend, U-Boot bbappend, bptool
│   ├── recipes-kernel/
│   │   ├── edge-kernel-fit/           # signed FIT (separate recipe, wrynose pattern)
│   │   └── linux/                     # linux-cip bbappend + kconfig fragments
│   ├── recipes-core/
│   │   ├── images/                    # edge-image-{base,common,dev} + WKS
│   │   ├── packagegroups/             # packagegroup-edge-* recipes
│   │   ├── edge-sudoers/              # %wheel ALL=(ALL:ALL) ALL  (password required)
│   │   ├── edge-sysctl-hardening/     # CIS L1 sysctl drops
│   │   └── edge-journald-hardening/   # persistent + sealed + size-bounded
│   ├── recipes-security/
│   │   ├── edge-audit/                # CIS L1 auditd rules, locked
│   │   └── optee/                     # OP-TEE bbappends
│   ├── recipes-ota/
│   │   ├── rauc/                      # system.conf + bundle hooks
│   │   └── bundles/                   # edge-bundle (verity-format)
│   └── recipes-support/
│       └── edge-banner/               # /etc/issue + /etc/motd + sshd hardening drop-in
│
├── scripts/
│   └── env.sh                         # source for standalone kas shell sessions
│
├── docs/
│   ├── adr/                           # 0001 kernel-base, 0002 layer-hosting
│   ├── security/                      # CRA controls + posture + verification cmds
│   └── dev/                           # operator workflows (netboot, …)
│
├── Makefile                           # see `make help` for all targets
├── AGENTS.md                          # orientation for AI coding agents (any vendor)
└── CLAUDE.md                          # Claude-Code-specific layered notes
```

Upstream layers (`bitbake`, `openembedded-core`, `meta-arm`,
`meta-openembedded`, `meta-rauc`, `meta-yocto`, `meta-renesas`)
are kas-cloned under `.kas/` (gitignored). They do **not** appear at
the repo root. The kas work-dir + git-alternates plumbing is in the
`Makefile`; the policy is documented in
[ADR 0002 — Layer hosting](docs/adr/0002-layer-hosting.md).

---

## Status

| Track | Status |
|---|---|
| Base boot (BL2 → BL31 → BL32 → U-Boot → FIT → kernel) | Wired and working |
| Signed FIT (dev-profile file key) | Wired |
| OP-TEE userspace (libteec + tee-supplicant + examples) | Wired in dev tier |
| RAUC A/B + bundle install hooks | Wired |
| Hardening (users + sshd + sysctl + auditd + journald + kernel cfg) | Wired |
| SBOM (SPDX 3.0.1) + CVE scanning | On by default |
| `edge-image-base`, `edge-image-dev` | Live |
| `edge-image-prod` (read-only rootfs, MODULE_SIG_FORCE, IMA enforce, no `package-management`) | Deferred |
| DM-VERITY rootfs (kernel symbols on; runtime wiring) | Deferred |
| HSM signing (SoftHSM + YubiKey ROT) | Deferred (file-key dev profile only today) |
| DRP-AI runtime (`meta-edge-ai` sibling layer) | Slot reserved in `kas/base.yml`; layer not built |
| HTTPS+mTLS OTA streaming | Deferred (RAUC streaming block in `system.conf` commented) |
| Multi-board (i.MX93, VF2, RPi5, Orin) | Layer boundaries audited & ready; no second board wired yet |

---

## Documentation

- [AGENTS.md](AGENTS.md) — full orientation for collaborators
  (humans and AI agents). Build commands, kas composition,
  recipe conventions, the "don't touch" set.
- [CLAUDE.md](CLAUDE.md) — Claude-Code-specific notes layered on top
  of `AGENTS.md` (skills, working context, wrynose recipe gotchas).
- [docs/adr/0001-kernel-base.md](docs/adr/0001-kernel-base.md) —
  kernel-base decision record (linux-cip 6.12 SLTS).
- [docs/security/README.md](docs/security/README.md) — security
  posture overview + on-board verification commands.
- [docs/security/CRA-CONTROLS.md](docs/security/CRA-CONTROLS.md) —
  per-requirement CRA Annex I mapping with implementation status.

---

## License + provenance

- Recipes and configuration in this repo are MIT-licensed.
- The Renesas RZ TF-A / U-Boot / OP-TEE forks pinned from
  [`renesas-rz/`](https://github.com/renesas-rz) carry their upstream
  BSD-3-Clause / GPL-2.0 / BSD-2-Clause licenses.
- The Renesas vendor BSP (`meta-renesas`) is cloned at build time from
  renesas-rz/meta-renesas (scarthgap/rz branch); it is not redistributed by this repo.
- SBOM (SPDX 3.0.1) is generated for every build under
  `build/tmp/deploy/spdx/`.

---

## Repo

[github.com/umair-as/edge-ai-yocto](https://github.com/umair-as/edge-ai-yocto)

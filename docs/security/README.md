# EDGE AI OS — Security & CRA Posture

The EDGE AI OS distro is built to demonstrate **CRA-by-design** (EU Cyber Resilience Act, Annex I) on a real RZ/V2L SMARC EVK, not to ship a hardened consumer product. The goals translate roughly as:

- Every credential is **operator-supplied**, not committed.
- The boot chain is **measured, signed, and reversible** — BL2 → BL31 → BL32 (OP-TEE) → BL33 (U-Boot) → FIT-signed kernel/DTB → RAUC-managed A/B rootfs.
- The runtime is **CIS-Level-1-aligned by default**, with prod-grade hardening as the trajectory.
- Every control is **documented + measurable**, so an auditor can map this image to CRA Annex I.

Two documents live here:

- [`README.md`](README.md) — this orientation page.
- [`CRA-CONTROLS.md`](CRA-CONTROLS.md) — per-requirement status table.

## What's enabled today (current image)

| Surface | Mechanism | Recipe / config |
|---|---|---|
| Boot integrity | TF-A 2.10.5 + OP-TEE 4.8 + signed FIT (`sha256,rsa2048:edge-fit-dev`) | `meta-edge-bsp/recipes-bsp/{trusted-firmware-a,u-boot,...}`, `meta-edge-bsp/recipes-kernel/edge-kernel-fit/` |
| Build-time userspace hardening | `security_flags.bbclass` (auto-inherit via `defaultsetup.conf`) — PIE / SSP-strong / FORTIFY_SOURCE / Wformat | distro-wide; verify `bitbake-getvar -r <recipe> SECURITY_CFLAGS` |
| Default credentials | `extrausers` with `EDGE_DEFAULT_PASSWORD_HASH` from operator's `kas/local.yml` (gitignored). Build fails noisily if unset. | `meta-edge-distro/conf/distro/include/edge-users.inc`, `kas/local.yml.example` |
| Login policy | `root` shell allowed on physical serial only; SSH denies root, allows `devel` (in `wheel` group). | `edge-banner` ships `sshd_config.d/20-edge-hardening.conf`; `edge-sudoers` ships `sudoers.d/10-edge-wheel` (password required, no NOPASSWD) |
| Kernel hardening | KASLR + kstack randomization, init-on-{alloc,free}, slab-freelist-{random,hardened}, hardened usercopy, stack-protector-strong, kexec off, /proc/kcore off, ldisc_autoload off, unpriv BPF off-default | `meta-edge-bsp/recipes-kernel/linux/files/security-hardening.cfg` |
| Kernel cmdline (boot args) | `init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none` | `meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults` — `rauc_set_bootargs` line |
| Sysctl drops | CIS L1 — dmesg/kptr restrict, unpriv userns + BPF off, ptrace_scope=1, protected_{symlinks,hardlinks,fifos,regular}, rp_filter, no ICMP redirects, no source route, no IP forward, SYN-cookies on, log_martians | `meta-edge-bsp/recipes-core/edge-sysctl-hardening/files/10-edge-hardening.conf` |
| Auditd ruleset | identity (passwd/group/shadow/sudoers), logins (wtmp/btmp/utmp/lastlog), sshd policy, kernel modules, time changes, network policy files, RAUC slot state, locked with `-e 2` | `meta-edge-bsp/recipes-security/edge-audit/files/10-edge.rules` |
| journald | persistent storage, bounded size (500M / 50M segments / 10 files), Forward{Syslog,KMsg,Wall}=no, rate-limited, `Seal=yes` | `meta-edge-bsp/recipes-core/edge-journald-hardening/` |
| Sudo | `%wheel ALL=(ALL:ALL) ALL` (password required) | `edge-sudoers` |
| SBOM + CVE | SPDX 3.0 + sbom-cve-check + pinned NVD/CVEList SHAs (always-on in `edge-ai.conf`) | `meta-edge-distro/conf/distro/edge-ai.conf` |

## What's infrastructure-ready, enforcement deferred

| Surface | Status | What's missing |
|---|---|---|
| Module signing | `CONFIG_MODULE_SIG=y`, `MODULE_SIG_ALL=y` | `MODULE_SIG_FORCE=y` + in-tree signing key flow → prod tier |
| DM-VERITY | Kernel symbols on, RAUC `bundle-formats=verity` | Rootfs verity image build, U-Boot/RAUC env wiring for root hash, kernel cmdline `root=/dev/dm-0 dm-mod.create=…` — see [`CRA-CONTROLS.md`](CRA-CONTROLS.md) |
| IMA/EVM | `CONFIG_INTEGRITY=y`, `IMA=y`, `EVM=y` | `ima_appraise=enforce` cmdline + signed policy chain |
| FIT-baked cmdline | FIT signing in place | Move hardening tokens from U-Boot env into FIT's `bootargs` so they're signed-image-immutable |
| AppArmor | LSM compiled in, profiles available | `DEFAULT_SECURITY_APPARMOR=y` + curated profile set |
| TPM2 binding | `meta-tpm2` loaded via `kas/tpm.yml` | TPM2 driver on RZ/V2L (likely SPI/I2C external chip), LUKS-volume key sealing flow |

## What's deliberately deferred (prod tier scope)

- `read-only-rootfs` + `stateless-rootfs` (rootfs immutability + tmpfs /etc)
- LUKS-encrypted `/data` partition with TPM-sealed key
- `PasswordAuthentication no` on SSH (pubkey-only)
- Provisioning service that mints per-device credentials at first boot
- Fail2ban + intrusion detection (`meta-ids`)
- OpenSCAP profile scans + CI gate

All listed in `CRA-CONTROLS.md` with planned-iteration markers.

## How to verify on-board

```sh
# Build hardening reached the binary
readelf -d /usr/bin/sshd | grep -E "Shared object|FLAGS"          # PIE bit
checksec --file /usr/bin/sshd                                    # full report

# Sysctl drops applied
sysctl kernel.dmesg_restrict kernel.kptr_restrict                # both 1, 2
sysctl fs.protected_symlinks fs.protected_hardlinks              # both 1

# Kernel hardening cmdline reached the kernel
cat /proc/cmdline | grep -o "init_on_alloc=1\|slab_nomerge\|randomize_kstack_offset=on"

# Login policy
grep -E "^(AllowUsers|PermitRootLogin|PasswordAuthentication)" /etc/ssh/sshd_config.d/*.conf
sudo -l                                                          # devel asks for password

# Audit running
systemctl status auditd
auditctl -l | head                                               # rules loaded
ausearch -k identity | tail                                      # try editing /etc/sudoers
```

## Audit / compliance notes

This is a public reference implementation. Treat the password hash, SSH keys, and signing keys in your operator-private `kas/local.yml` as the **only** credentials that should ever exist for *your* build. Don't share `local.yml`. Don't commit it.

The CRA mapping in [`CRA-CONTROLS.md`](CRA-CONTROLS.md) is a **claim of trajectory**, not certification. Real CRA conformance requires an external assessment, an SBOM-driven vulnerability handling process, and per-device unique credentials — all of which are roadmap items here.

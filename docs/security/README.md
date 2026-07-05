# EDGE AI OS — Security Posture

EDGE AI OS is designed to satisfy the essential cybersecurity requirements of EU Cyber Resilience Act (CRA) Annex I on a real RZ/V2L SMARC EVK. The design goals are:

- Every credential is **operator-supplied**, not committed.
- The boot chain is **measured, signed, and reversible** — BL2 → BL31 → BL32 (OP-TEE) → BL33 (U-Boot) → FIT-signed kernel/DTB → RAUC-managed A/B rootfs.
- The runtime is **CIS Level 1-aligned by default**, with additional hardening controls on the prod-tier roadmap.
- Every control is **documented and verifiable on-board**, so the implementation can be mapped to CRA Annex I requirements.

Documents here:

- [`README.md`](README.md) — this orientation page.
- [`CRA-CONTROLS.md`](CRA-CONTROLS.md) — per-requirement status table.
- [`uboot-hardening.md`](uboot-hardening.md) — U-Boot surface-reduction
  architecture, feature tokens, and per-symbol rationale.
- [`selinux-101.md`](selinux-101.md) — SELinux mental model + the
  `meta-selinux` wiring on this distro.
- [`sbom-cve-triage.md`](sbom-cve-triage.md) — reading the SBOM + CVE
  artifacts and the `CVE_STATUS` triage workflow (`scripts/sbom-cve-report.py`).
- [`foss-cra-tooling-survey.md`](foss-cra-tooling-survey.md) — mid-2026 market
  survey of the FOSS vuln-management stack (VEX, scanners, Dependency-Track,
  VulnScout) and an honest view of its strengths and limits.

## What's enabled today (current image)

| Surface | Mechanism | Recipe / config |
|---|---|---|
| Boot integrity | TF-A 2.10.5 + OP-TEE 4.8 + signed FIT (`sha256,rsa2048:edge-fit-dev`) | `meta-edge-bsp/recipes-bsp/{trusted-firmware-a,u-boot,...}`, `meta-edge-bsp/recipes-kernel/edge-kernel-fit/` |
| Build-time userspace hardening | `security_flags.bbclass` (auto-inherit via `defaultsetup.conf`) — PIE / SSP-strong / FORTIFY_SOURCE / Wformat | distro-wide; verify `bitbake-getvar -r <recipe> SECURITY_CFLAGS` |
| Default credentials | `extrausers` with `EDGE_DEFAULT_PASSWORD_HASH` from operator's `kas/local.yml` (gitignored). Build fails noisily if unset. | `meta-edge-distro/conf/distro/include/edge-users.inc`, `kas/local.yml.example` |
| Login policy | `root` shell allowed on physical serial only; SSH denies root, allows `devel` (in `wheel` group). | `edge-sshd-hardening` ships `sshd_config.d/99-edge-hardening.conf`; `edge-sudoers` ships `sudoers.d/10-edge-wheel` (password required, no NOPASSWD) |
| Kernel hardening | KASLR + kstack randomization, init-on-{alloc,free}, slab-freelist-{random,hardened}, hardened usercopy, stack-protector-strong, kexec off, /proc/kcore off, ldisc_autoload off, unpriv BPF off-default. LSM stack `lockdown,yama,bpf,landlock,selinux` | `meta-edge-bsp/recipes-kernel/linux/files/security-hardening.cfg` |
| Kernel cmdline (boot args) | `init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none` | `meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults` — `rauc_set_bootargs` line |
| Sysctl drops | CIS L1 — dmesg/kptr restrict, unpriv BPF off (userns left enabled for rootless containers), ptrace_scope=1, protected_{symlinks,hardlinks,fifos,regular}, rp_filter, no ICMP redirects, no source route, no IP forward, SYN-cookies on, log_martians | `meta-edge-bsp/recipes-core/edge-sysctl-hardening/files/70-edge-hardening.conf` |
| Auditd ruleset | identity (passwd/group/shadow/sudoers), logins (wtmp/btmp/utmp/lastlog), sshd policy, kernel modules, time changes, network policy files, RAUC slot state, locked with `-e 2` | `meta-edge-bsp/recipes-security/edge-audit/files/10-edge.rules` |
| journald | persistent storage, bounded size (200M / 50M segments / 10 files), Forward{Syslog,KMsg,Wall}=no, rate-limited; integrity via `journalctl --verify` hash chain (FSS deprecated upstream) | `meta-edge-bsp/recipes-core/edge-journald-hardening/` |
| Sudo | `%wheel ALL=(ALL:ALL) ALL` (password required) | `edge-sudoers` |
| SBOM + CVE | SPDX 3.0.1 + sbom-cve-check + pinned NVD/CVEList SHAs (always-on in `edge-ai.conf`) | `meta-edge-distro/conf/distro/edge-ai.conf` |

## What's infrastructure-ready, enforcement deferred

| Surface | Status | What's missing |
|---|---|---|
| Module signing | `CONFIG_MODULE_SIG=y`, `MODULE_SIG_ALL=y` | `MODULE_SIG_FORCE=y` + in-tree signing key flow → prod tier |
| DM-VERITY | Kernel symbols on, RAUC `bundle-formats=verity` | Rootfs verity image build, U-Boot/RAUC env wiring for root hash, kernel cmdline `root=/dev/dm-0 dm-mod.create=…` |
| IMA/EVM | `CONFIG_INTEGRITY=y`, `IMA=y`, `EVM=y` | `ima_appraise=enforce` cmdline + signed policy chain |
| FIT-baked cmdline | FIT signing in place | Move hardening tokens from U-Boot env into FIT's `bootargs` so they're signed-image-immutable |
| SELinux enforcing | MCS policy validated in permissive | `selinux=1 enforcing=1` boot with full AVC-clean policy set |
| TPM2 binding | `meta-tpm2` loaded via `kas/tpm.yml` | TPM2 driver on RZ/V2L (likely SPI/I2C external chip), LUKS-volume key sealing flow |

## What's deliberately deferred (prod tier scope)

- `read-only-rootfs` + `stateless-rootfs` (rootfs immutability + tmpfs /etc)
- LUKS-encrypted `/data` partition with TPM-sealed key
- `PasswordAuthentication no` on SSH (pubkey-only)
- Provisioning service that mints per-device credentials at first boot
- Fail2ban + intrusion detection (`meta-ids`)
- OpenSCAP profile scans + CI gate

## How to verify on-board

```sh
# Build-flag hardening (PIE / RELRO / SSP / FORTIFY) is asserted at build time —
# verify with `bitbake-getvar -r <recipe> SECURITY_CFLAGS` (see table above).
# No ELF-inspection tool (binutils/checksec) ships on the default image.

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

This is a public reference implementation. The password hash, SSH keys, and signing keys in your operator-private `kas/local.yml` are the only credentials that should exist for a given build. Do not share or commit `local.yml`.

This is a reference implementation: a hardened, secure-by-default distro that delivers the technical controls of CRA Annex I, Part 1 — measured and signed boot, atomic signed updates with rollback, a least-privilege runtime, and SBOM plus CVE scanning on by default. The manufacturer-side pieces a fielded product adds — a coordinated vulnerability-handling process (Annex I, Part 2) and per-device credential provisioning — live outside the image and are out of scope for this repo.

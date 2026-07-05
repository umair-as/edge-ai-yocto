# CRA Annex I — Controls Mapping

EU Cyber Resilience Act, Annex I (essential cybersecurity requirements). This table tracks each requirement against EDGE AI OS's implementation status.

| Status | Meaning |
|---|---|
| ✅ **Implemented** | Active in the current image; verifiable on-board |
| 🟡 **Infrastructure ready** | Code path + libraries in place; enforcement / wiring deferred |
| 📅 **Planned** | Targeted for a named upcoming iteration |
| ⏸ **Deferred** | Acknowledged scope; no current owner |

> This is a *claim of trajectory*, not certification. CRA conformance requires external assessment, a vulnerability handling process, and per-device unique credentials at provisioning. Treat this document as the engineering log.

---

## Annex I, Part I — Essential requirements

### 1. Secure by default — minimum attack surface

| Sub-requirement | Status | Implementation |
|---|---|---|
| 1.a — Minimum attack surface (no unnecessary services) | ✅ | Base image is minimal Weston; dev image opt-in via packagegroups. `tools-debug` / `tools-profile` only in `edge-image-dev`. No demo / sample daemons. U-Boot surface reduction via `EDGE_UBOOT_FEATURES` — see [uboot-hardening.md](uboot-hardening.md). |
| 1.b — Hardened build flags | ✅ | `security_flags.bbclass` auto-inherited. `SECURITY_CFLAGS` = `-fstack-protector-strong -O2 -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security -Werror=format-security`. Userspace built PIE. U-Boot stack canary via `CONFIG_STACKPROTECTOR=y` (see uboot-hardening.md). |
| 1.c — Kernel hardening | ✅ | `security-hardening.cfg` fragment + `rauc_set_bootargs` tokens (init_on_alloc, slab_nomerge, page_alloc.shuffle, randomize_kstack_offset, vsyscall=none). LSM stack `CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"` — lockdown (early, `SECURITY_LOCKDOWN_LSM_EARLY=y`) + landlock compiled in. |
| 1.d — Sysctl baseline | ✅ | `edge-sysctl-hardening` — CIS L1. |
| 1.e — Read-only rootfs | 📅 | Prod tier — separate `edge-image-prod.bb` (not in this iteration). |

### 2. No known exploitable vulnerabilities at time of release

| Sub-requirement | Status | Implementation |
|---|---|---|
| 2.a — SBOM | ✅ | SPDX 3.0.1 always-on via `OE_FRAGMENTS += "yocto/sbom-cve-check"`. |
| 2.b — CVE scanning at build | ✅ | `sbom-cve-check-update-{nvd,cvelist}-native` pulled into every build. SRCREVs pinned (no AUTOREV drift). |
| 2.c — Fail-on-critical-CVE policy | 🟡 | Sketched in `kas/sbom-cve.yml` as `IMAGE_POSTPROCESS_COMMAND` hook; wiring deferred until SBOM-walk script is written. |
| 2.d — Vulnerability handling process | 📅 | Needs `docs/security/VULN-HANDLING.md` describing report intake, triage SLA, fix-vs-mitigate, OTA push. Phase 2. |

### 3. Confidential authentication / no default passwords

| Sub-requirement | Status | Implementation |
|---|---|---|
| 3.a — No committed credentials | ✅ | `EDGE_DEFAULT_PASSWORD_HASH` lives in operator-private `kas/local.yml`. Build fails if unset. |
| 3.b — Two-account separation | ✅ | `root` (serial only) + `devel` (SSH-reachable, in wheel). Password hash from operator. |
| 3.c — SSH login policy | ✅ | `AllowUsers devel`, `PermitRootLogin no`, modern Ciphers/Kex/MACs, `MaxAuthTries 6`. |
| 3.d — Sudo via wheel, password required | ✅ | `edge-sudoers` ships `%wheel ALL=(ALL:ALL) ALL` (no NOPASSWD). |
| 3.e — Pubkey baked at build | ✅ | `EDGE_DEVEL_SSH_PUBKEY_FILE` from `kas/local.yml`. Optional — falls back to password auth. |
| 3.f — Password-quality enforcement | ✅ | `libpwquality` (PAM) in `packagegroup-edge-security` — strength checks on password set/change. |
| 3.g — Per-device unique credentials | 📅 | First-boot provisioning service that mints per-device hash from `/etc/machine-id` + writes to `/etc/passwd` + prints to serial. Deferred to a separate iteration with thorough recovery testing. |

### 4. Confidentiality of data at rest

| Sub-requirement | Status | Implementation |
|---|---|---|
| 4.a — DM-VERITY rootfs (immutable) | 🟡 | Kernel symbols on (`CONFIG_DM_VERITY=y`, `DM_VERITY_FEC=y`, `BLK_DEV_DM=y`, `DM_INIT=y`). RAUC bundle format already `verity`. Boot-flow wiring deferred — needs `rauc_set_bootargs` change to construct `root=/dev/dm-0 dm-mod.create=...` from active-slot root hash. |
| 4.b — `/data` LUKS encryption | 🟡 | `cryptsetup` (LUKS + `veritysetup`) userspace ships in `packagegroup-edge-security`. No wiring yet. Needs TPM2 chip on the board (RZ/V2L doesn't have internal TPM) OR PBKDF-derived key from per-device secret. |
| 4.c — Key material protection | ⏸ | TPM-sealed LUKS key. Same blocker as 4.b. |

### 5. Confidentiality + integrity of data in transit

| Sub-requirement | Status | Implementation |
|---|---|---|
| 5.a — TLS client trust store | ✅ | `ca-certificates` (Mozilla bundle) in `packagegroup-edge-security`. |
| 5.b — Modern SSH ciphers | ✅ | curve25519-sha256, chacha20-poly1305, aes-gcm only (`edge-sshd-hardening` → `sshd_config.d/99-edge-hardening.conf`). |
| 5.c — TLS for OTA bundles | 🟡 | `rauc-conf-edge` uses `bundle-formats=verity` (integrity). Streaming-over-TLS deferred — RAUC streaming section commented in `system.conf`. |

### 6. Integrity protection

| Sub-requirement | Status | Implementation |
|---|---|---|
| 6.a — Signed boot chain | ✅ | TF-A (BL2/BL31) → OP-TEE (BL32) → U-Boot (BL33). RAUC bundle signed. |
| 6.b — Signed FIT image | ✅ | `sha256,rsa2048:edge-fit-dev` — kernel + DTB signatures verified by U-Boot's control DTB pubkey. |
| 6.c — DM-VERITY at runtime | 🟡 | See 4.a. |
| 6.d — Module signing | 🟡 | `MODULE_SIG=y`, `MODULE_SIG_ALL=y`. `MODULE_SIG_FORCE=y` deferred to prod tier. |
| 6.e — IMA appraisal | 🟡 | Kernel `CONFIG_IMA=y`, `IMA_LSM_RULES=y`. `ima_appraise=enforce` cmdline + signed policy deferred. |

### 7. Minimisation of data processed

| Sub-requirement | Status | Implementation |
|---|---|---|
| 7 — Process only what's necessary for declared function | ✅ | Image scope is bring-up. No telemetry. No phone-home. RAUC OTA is operator-triggered, not background-polled. |

### 8. Availability + resilience

| Sub-requirement | Status | Implementation |
|---|---|---|
| 8.a — A/B rootfs with rollback | ✅ | RAUC `rootfs.0` + `rootfs.1` + boot-attempts counter in U-Boot env. |
| 8.b — Watchdog | ✅ | `watchdog@12800800` started in U-Boot + kept by kernel. |
| 8.c — Bounded log usage | ✅ | journald `SystemMaxUse=200M`, `SystemMaxFileSize=50M`. |

### 9. Protective measures against DoS

| Sub-requirement | Status | Implementation |
|---|---|---|
| 9.a — SYN cookies | ✅ | `net.ipv4.tcp_syncookies=1`. |
| 9.b — Sshd rate limiting | ✅ | `MaxAuthTries 6`, `LoginGraceTime 30`, `MaxStartups 10:30:60`. |
| 9.c — journald rate limiting | ✅ | 1000 messages / 30s. |
| 9.d — fail2ban / brute-force lockout | 📅 | `meta-security` provides `fail2ban`. Not yet in `packagegroup-edge-security`. Phase 2. |

### 10. Limit impact of security incidents

| Sub-requirement | Status | Implementation |
|---|---|---|
| 10.a — Audit trail | ✅ | `edge-audit` — CIS L1 rules, immutable (`-e 2`). |
| 10.b — Tamper-evident logs | 🟡 | Integrity at rest is the journald structural hash chain, validated by `journalctl --verify`. FSS (`Seal=yes`) was upstream-deprecated in systemd 257 and is a no-op on wrynose (systemd 259); a sealed remote aggregator is the planned path. |
| 10.c — Privilege separation | ✅ | `root` not SSH-reachable; `devel` sudo with password; no NOPASSWD shortcuts. |
| 10.d — Mandatory access control | 🟡 | SELinux MCS — `DISTRO_FEATURES += selinux`, `refpolicy-mcs` + `selinux-autorelabel`, `CONFIG_DEFAULT_SECURITY_SELINUX=y`, in the `CONFIG_LSM` stack; AppArmor explicitly off. Permissive baseline; `enforcing=1` validated on-board via controlled reboot, full AVC-clean policy set deferred. |
| 10.e — Rootless-container isolation | ✅ | DRP-AI inference runs in rootless Podman under a dedicated `edge-ctr` principal (uid 608, per-principal subuid namespace) with SELinux `container_t` — no root, no capability widening. HW-validated, zero AVC denials. |

### 11. Security-relevant info recording

| Sub-requirement | Status | Implementation |
|---|---|---|
| 11.a — System events logged | ✅ | journald persistent + auditd. |
| 11.b — Build provenance | ✅ | `EDGE_BUILD_ID` from `SOURCE_DATE_EPOCH` in `/etc/issue` + RAUC bundle name (planned). |
| 11.c — Boot provenance | ✅ | BL2 banner carries `EDGE_BUILD_TAG`; U-Boot banner same. |

### 12. Secure updates

| Sub-requirement | Status | Implementation |
|---|---|---|
| 12.a — Signed OTA bundles | ✅ | RAUC bundle signed by `edge-fit-dev` keychain. |
| 12.b — Atomic install + rollback | ✅ | A/B slot architecture. |
| 12.c — Update transport authenticity | 🟡 | Bundle signature is checked locally. HTTPS streaming with mTLS deferred (`rauc-conf-edge` has the `[streaming]` block commented; lands in Phase 2). |
| 12.d — Update without user interruption | ✅ | RAUC install while running; reboot to flip slot. |

### 13. Possibility to delete all data + settings

| Sub-requirement | Status | Implementation |
|---|---|---|
| 13.a — Factory reset path | 📅 | No documented procedure yet. Needs `edge-factory-reset` recipe + serial-console invocation. Phase 2. |

---

## Annex I, Part II — Vulnerability handling requirements

(Manufacturer-side processes; tracked separately because they're operational, not embedded.)

| Requirement | Status | Notes |
|---|---|---|
| Coordinated disclosure process | 📅 | Need `docs/security/SECURITY.md` + intake email + GitHub Security Advisory enablement. |
| Vulnerability response SLAs | 📅 | Need policy document. |
| SBOM-driven patch path | 🟡 | We have SBOMs at every build; CI gate that diffs SBOMs across releases not yet wired. |
| Free security updates over supported lifetime | 📅 | Lifetime not yet declared. CIP-aligned implies ≥10y; needs commitment. |

---

## Workflow for adding controls

When implementing the next deferred item:

1. Update the relevant row from 📅 / ⏸ → 🟡 (when infra lands) → ✅ (when verifiable on-board).
2. Add the verification command to `docs/security/README.md` § "How to verify on-board".
3. If the control crosses tier boundaries (base vs dev vs prod), note the per-tier delta.
4. Cross-link the recipe / configuration file path so an auditor can grep-jump.

When **removing** a control (e.g. trimming auditd rules for performance), drop the row to ⏸ with a one-sentence justification — never just delete.

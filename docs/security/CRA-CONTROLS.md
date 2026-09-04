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
| 1.b — Hardened build flags | ✅ | `security_flags.bbclass` auto-inherited. `SECURITY_CFLAGS` = `-fstack-protector-strong -O2 -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security -Werror=format-security`. Userspace built PIE. U-Boot stack canary deferred — `CONFIG_STACKPROTECTOR` off pending a proof build (see uboot-hardening.md "Explicit deferrals"). |
| 1.c — Kernel hardening | ✅ | `security-hardening.cfg` plus hardening arguments embedded in the signed slot DTBs. LSM stack includes lockdown, yama, BPF, landlock, and SELinux; lockdown is compiled but not activated. |
| 1.d — Sysctl baseline | ✅ | `edge-sysctl-hardening` — CIS L1. |
| 1.e — Read-only rootfs | ✅ | All A/B images use a read-only dm-verity mapping; persistent writes live under `/data`. |

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
| 4.a — DM-VERITY rootfs (immutable) | ✅ | RAUC raw-writes `ext4.verity`; the signed slot FIT supplies the root hash and early `dm-mod.create`, mounting `/dev/dm-0` read-only. On-target flash, boot, deliberate corruption detection, and OTA replacement/rollback validation are complete. |
| 4.b — `/data` LUKS encryption | 🟡 | `cryptsetup` (LUKS + `veritysetup`) userspace ships in `packagegroup-edge-security`. No wiring yet. Needs TPM2 chip on the board (RZ/V2L doesn't have internal TPM) OR PBKDF-derived key from per-device secret. |
| 4.c — Key material protection | ⏸ | TPM-sealed LUKS key. Same blocker as 4.b. |

### 5. Confidentiality + integrity of data in transit

| Sub-requirement | Status | Implementation |
|---|---|---|
| 5.a — TLS client trust store | ✅ | `ca-certificates` (Mozilla bundle) in `packagegroup-edge-security`. |
| 5.b — Modern SSH ciphers | ✅ | curve25519-sha256, chacha20-poly1305, aes-gcm only (`edge-sshd-hardening` → `sshd_config.d/99-edge-hardening.conf`). |
| 5.c — TLS for OTA bundles | ✅ | The `bundle-formats` allowlist (`verity crypt` by default; see 5.d) enforces integrity, plus mTLS transport: the `[streaming]` block in `system.conf` binds a client cert/key and CA, and the transfer runs as the unprivileged `ota` user. Hardware-validated on RZ/V2L — a 253 MB bundle streamed over HTTPS with client-certificate auth and installed to the inactive slot. Requires a per-device identity in `/etc/ota` (`EDGE_OTA_CERT_DIR`); not shipped by default. |
| 5.d — OTA bundle payload confidentiality | 🟡 | RAUC `crypt` bundles (AES-256 payload, manifest CMS-enveloped to recipient certs) wired behind `EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION`, **on by default since 2026-09-04**. Kernel side verified present (`CONFIG_DM_CRYPT` and the AES/CBC deps are `=y` in the built config); recipient key generation, image provisioning and `bundle-formats` switching are wired and **hardware-validated** — a transition release then a crypt release both installed over ordinary OTA on RZ/V2L, booted, and passed the verity/smoke-test suite on both slots. Still 🟡, not ✅: the dev flow uses one shared fleet key with no revocation path, and the default now bakes that key into every image rather than requiring an explicit opt-in. See [ota-updates.md](../dev/ota-updates.md). |

### 6. Integrity protection

| Sub-requirement | Status | Implementation |
|---|---|---|
| 6.a — Signed boot chain | 🟡 | U-Boot verifies FIT configurations and RAUC verifies bundles, but TF-A has `TRUSTED_BOARD_BOOT=0`; BL2 through BL33 are not hardware-authenticated. |
| 6.b — Signed FIT image | ✅ | `sha256,rsa2048:edge-fit-dev` covers the kernel and slot DTB, including the root hash. Interactive U-Boot commands can still bypass the managed boot macro. |
| 6.c — DM-VERITY at runtime | ✅ | See 4.a; the mapped root was validated on target through flash, boot, deliberate corruption detection, and OTA replacement/rollback. |
| 6.d — Module signing | ✅ | `MODULE_SIG=y`, `MODULE_SIG_ALL=y`, and `MODULE_SIG_FORCE=y`; hand-installed Renesas modules use the shared signing include. |
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
| 12.c — Update transport authenticity | ✅ | Two independent layers: the bundle signature is verified against the device keyring regardless of transport, and the transport itself is mutually authenticated — the device presents a client certificate and validates the server against its own CA. Both exercised in the same hardware-validated streaming install; signature verification happens over the stream, before any slot is written. |
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

# Security baseline for edge AI

The security controls of EDGE AI OS, starting with the part that makes it an
edge AI platform: how models and inference payloads reach the device, how the
accelerator is isolated, and what a compromised inference container can reach.
The platform controls follow (boot, credentials, kernel, updates, logging), then
the vulnerability-handling process.

Each row states what is implemented and how to check it. This is an engineering
baseline built from established embedded Linux practice (CIS Level 1 for the
runtime, the KSPP kernel recommendations, signed A/B updates, SBOM and CVE
scanning); it makes no claim of conformance to any regulation or standard.

| Status | Meaning |
|---|---|
| ✅ **Implemented** | Active in the current image; verifiable on-board |
| 🟡 **Infrastructure ready** | Code path + libraries in place; enforcement or wiring missing |
| 📅 **Planned** | On the roadmap, not in the image |
| ⏸ **Deferred** | Acknowledged scope; no current owner |

---

## Edge AI surface

### Model and payload delivery

A device carries three things that change at different rates: the platform
(bootloader, kernel, rootfs), the inference application, and the compiled model.
Each needs its own integrity story, because they do not share a rollback domain
([ADR-0010](../adr/0010-model-artifact-delivery.md)).

| Control | Status | Implementation |
|---|---|---|
| Platform delivered as signed A/B updates | ✅ | RAUC bundles carry the dm-verity rootfs and the signed per-slot FITs; see §12. A model never travels in a platform bundle. |
| Inference payload kept off the A/B rootfs | ✅ | The runner, runtime libraries and compiled model live under `/data/drpai` (RZ/V2L) or `/data/dxm1` (Raspberry Pi 5), survive slot swaps, and are bind-mounted **read-only** into the container. The Quadlet does not start when the payload is absent (`ConditionPathExists`). |
| Payload integrity on the device | ⏸ | Payloads are placed on `/data` by the operator. Nothing on the device verifies them before the inference unit runs them. |
| Model as a signed, content-addressed artifact | 🟡 | ModelPack-compatible OCI artifact, deterministic construction and an independent inspector in `scripts/modelpack/` ([ADR-0010](../adr/0010-model-artifact-delivery.md), [model-delivery.md](../drp-ai/model-delivery.md)). Signature-before-extraction was hardware-verified on a prototype artifact: signed accepted; unsigned, wrong-key and corrupted refused. No device-side model store, activation or rollback exists. |
| Model-signing key separate from platform keys | 🟡 | Decided in ADR-0010 §5, with no device-side consumer to enforce it: the model key is not the FIT, RAUC, OTA-mTLS or bundle-encryption key, so a compromised model key asserts nothing about firmware. |
| Container base image authenticity | ⏸ | The inference Quadlets name `docker.io/library/debian:trixie-slim` with `Pull=missing`. The image ships no `policy.json` signature policy, so the base image is trusted on first pull. |

### Accelerator isolation

| Control | Status | Implementation |
|---|---|---|
| Dedicated inference principal | ✅ | `edge-ctr` (static uid/gid 608, `nologin`, home `/data/edge-ctr` mode 0700) runs the inference Quadlet under rootless Podman with linger, so it starts at boot without a login session. Recipe: `edge-ctr-user`. |
| User-namespace confinement | ✅ | Container uid 0 maps to `edge-ctr`; the rest of the container maps to the subordinate range 200000–265535, disjoint from `devel` (100000–165535). Ranges are written at image seal (`edge-users.inc`). |
| Device access by group, not root | ✅ | Accelerator nodes are `0660`: `/dev/drpai0` and `/dev/udmabuf0` group `render` (RZ/V2L, `edge-drpai-udev`), `/dev/dxrt*` group `dxrt` (Raspberry Pi 5, `edge-dxm1-runtime`). `GroupAdd=keep-groups` carries `edge-ctr`'s membership into the container; nothing else is passed through. |
| No capability widening | ✅ | The Quadlets add no capabilities, no `--privileged`, and no device beyond the accelerator nodes. |
| SELinux confinement | 🟡 | Containers run as `container_t`. Hardware-validated with zero AVC denials on RZ/V2L, but the image boots SELinux **permissive**, so `container_t` denials are logged, not enforced. |
| Accelerator daemon (DX-M1) | ✅ | `dxrtd` runs as the `dxrt` user, not root, with `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome` and `PrivateTmp`; its socket directory `/run/dxrt` is `0750`. |

### What a compromised inference container can reach

Assumes code execution inside the inference container, for example through a
malicious model that exploits the runner. The reach is that of `edge-ctr` inside
its user namespace, with SELinux permissive.

| Surface | RZ/V2L (DRP-AI) | Raspberry Pi 5 (DX-M1) |
|---|---|---|
| Accelerator | `/dev/drpai0` and the zero-copy input buffer `/dev/udmabuf0` (a CMA region). Can submit arbitrary work to the accelerator. | `/dev/dxrt0`, plus the `dxrtd` control socket at `/run/dxrt/ipc.sock`. Can submit arbitrary work through the daemon. |
| Filesystem | Its payload `/data/drpai`, read-only. No other host path is mounted. | Its payload `/data/dxm1`, read-only, and `/run/dxrt`. No other host path is mounted. |
| Processes | Its own PID namespace. | **The host PID namespace** (`--pid=host`, required by libdxrt's daemon liveness check): every host process and its command line is visible. Signalling or tracing processes of other users is blocked (separate uid, no capabilities in the host user namespace, `ptrace_scope=1`). |
| Network | Rootless default (pasta): outbound connections from the device's address. No inbound port is published. | Same. |
| Persistent state | Writes only inside its own container storage under `/data/edge-ctr`. Cannot modify the payload or the rootfs (dm-verity, read-only). | Same. |
| Escalation path | A kernel or driver bug reachable through the accelerator ioctl surface; the driver is out-of-tree vendor code. | Same, plus any `dxrtd` bug reachable over its socket (the daemon is unprivileged). |

Narrowing that reach is roadmap work: SELinux enforcing, `Network=none` for an
offline runner, a signature policy for the base image, and a verified model store.

---

## Platform controls

### 1. Minimum attack surface and hardening

| Control | Status | Implementation |
|---|---|---|
| 1.a — Minimum attack surface (no unnecessary services) | ✅ | Base image is minimal (Weston only where `EDGE_ENABLE_DISPLAY=1`; the Raspberry Pi 5 composition is headless); dev image opt-in via packagegroups. `tools-debug` / `tools-profile` only in `edge-image-dev`. No demo / sample daemons. U-Boot surface reduction via `EDGE_UBOOT_FEATURES` — see [uboot-hardening.md](uboot-hardening.md). |
| 1.b — Hardened build flags | ✅ | `security_flags.bbclass` auto-inherited. `SECURITY_CFLAGS` = `-fstack-protector-strong -O2 -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security -Werror=format-security`. Userspace built PIE. U-Boot stack canary off — `CONFIG_STACKPROTECTOR` awaits a proof build (see uboot-hardening.md "Explicit deferrals"). |
| 1.c — Kernel hardening | ✅ | `security-hardening.cfg` plus hardening arguments embedded in the signed slot DTBs. LSM stack includes lockdown, yama, landlock, SELinux, and BPF (BPF last, or it shadows SELinux's procattr hooks); lockdown is compiled but not activated. The prod `.config` is gated against a KSPP baseline in every prod kernel build (`do_edge_khc_gate`, `edge-kernel-policy.inc`); snapshot and baseline in [kernel-config/](kernel-config/README.md). |
| 1.d — Sysctl baseline | ✅ | `edge-sysctl-hardening` — CIS L1. |
| 1.e — Read-only rootfs | ✅ | All A/B images use a read-only dm-verity mapping; persistent writes live under `/data`. |

### 2. Known vulnerabilities at release

| Control | Status | Implementation |
|---|---|---|
| 2.a — SBOM | ✅ | SPDX 3.0.1 always-on via `OE_FRAGMENTS += "yocto/sbom-cve-check"`. |
| 2.b — CVE scanning at build | ✅ | `sbom-cve-check-update-{nvd,cvelist}-native` pulled into every build. SRCREVs pinned (no AUTOREV drift). |
| 2.c — Fail-on-critical-CVE policy | 🟡 | Sketched in `kas/sbom-cve.yml` as an `IMAGE_POSTPROCESS_COMMAND` hook; not wired, it needs an SBOM-walk script. |
| 2.d — Vulnerability handling process | 🟡 | [`VULN-HANDLING.md`](VULN-HANDLING.md) + [ADR-0013](../adr/0013-vulnerability-handling-cadence-and-release-gate.md): reachability triage, fix-vs-mitigate, verification, release gate, OTA delivery via RAUC. No response-time commitment by design; report intake not covered (see [Vulnerability handling process](#vulnerability-handling-process)). |

### 3. Credentials and authentication

| Control | Status | Implementation |
|---|---|---|
| 3.a — No committed credentials | ✅ | `EDGE_DEFAULT_PASSWORD_HASH` lives in operator-private `kas/local.yml`. Build fails if unset. |
| 3.b — Two-account separation | ✅ | `root` (serial only) + `devel` (SSH-reachable, in wheel). Password hash from operator. |
| 3.c — SSH login policy | ✅ | `AllowUsers devel`, `PermitRootLogin no`, modern Ciphers/Kex/MACs, `MaxAuthTries 6`. |
| 3.d — Sudo via wheel, password required | ✅ | `edge-sudoers` ships `%wheel ALL=(ALL:ALL) ALL` (no NOPASSWD) on base and prod; only `edge-image-dev` adds the NOPASSWD override. |
| 3.e — Pubkey baked at build | ✅ | `EDGE_DEVEL_SSH_PUBKEY_FILE` from `kas/local.yml`. Optional — falls back to password auth. |
| 3.f — Password-quality enforcement | ✅ | `libpwquality` (PAM) in `packagegroup-edge-security` — strength checks on password set/change. |
| 3.g — Per-device unique credentials | 📅 | First-boot provisioning service that mints a per-device hash from `/etc/machine-id`, writes it to `/etc/passwd` and prints it to serial. Needs thorough recovery testing. |

### 4. Data at rest

| Control | Status | Implementation |
|---|---|---|
| 4.a — dm-verity rootfs (immutable) | ✅ | RAUC raw-writes `ext4.verity`; the signed slot FIT supplies the root hash and early `dm-mod.create`, mounting `/dev/dm-0` read-only. On-target flash, boot, deliberate corruption detection, and OTA replacement/rollback validation are complete. |
| 4.b — `/data` LUKS encryption | 🟡 | `cryptsetup` (LUKS + `veritysetup`) userspace ships in `packagegroup-edge-security`, unwired. Needs an external TPM2 chip (neither board has an internal TPM) or a PBKDF-derived key from a per-device secret. |
| 4.c — Key material protection | ⏸ | TPM-sealed LUKS key. Same blocker as 4.b. |

### 5. Data in transit

| Control | Status | Implementation |
|---|---|---|
| 5.a — TLS client trust store | ✅ | `ca-certificates` (Mozilla bundle) in `packagegroup-edge-security`. |
| 5.b — Modern SSH ciphers | ✅ | curve25519-sha256, chacha20-poly1305, aes-gcm only (`edge-sshd-hardening` → `sshd_config.d/99-edge-hardening.conf`). |
| 5.c — TLS for OTA bundles | ✅ | The `bundle-formats` allowlist (`verity crypt` by default; see 5.d) enforces integrity, plus mTLS transport: the `[streaming]` block in `system.conf` binds a client cert/key and CA, and the transfer runs as the unprivileged `ota` user. Hardware-validated on RZ/V2L — a 253 MB bundle streamed over HTTPS with client-certificate auth and installed to the inactive slot. Requires a per-device identity in `/etc/ota` (`EDGE_OTA_CERT_DIR`); not shipped by default. |
| 5.d — OTA bundle payload confidentiality | 🟡 | RAUC `crypt` bundles (AES-256 payload, manifest CMS-enveloped to recipient certs) wired behind `EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION`, **on by default since 2026-09-04**. Kernel side verified present (`CONFIG_DM_CRYPT` and the AES/CBC deps are `=y` in the built config); recipient key generation, image provisioning and `bundle-formats` switching are wired and **hardware-validated** — a transition release then a crypt release both installed over ordinary OTA on RZ/V2L, booted, and passed the verity/smoke-test suite on both slots. 🟡, not ✅: the dev flow uses one shared fleet key with no revocation path, and the default bakes that key into every image rather than requiring an explicit opt-in. See [ota-updates.md](../dev/ota-updates.md). |

### 6. Integrity protection

| Control | Status | Implementation |
|---|---|---|
| 6.a — Signed boot chain | 🟡 | U-Boot verifies FIT configurations and RAUC verifies bundles on both boards, but nothing below U-Boot is hardware-authenticated: on RZ/V2L TF-A has `TRUSTED_BOARD_BOOT=0` (BL2 through BL33 unauthenticated); on the Raspberry Pi 5 the firmware loads U-Boot unauthenticated. |
| 6.b — Signed FIT image | ✅ | `sha256,rsa2048:edge-fit-dev` covers the kernel and slot DTB, including the root hash. Interactive U-Boot commands can still bypass the managed boot macro. |
| 6.c — dm-verity at runtime | ✅ | See 4.a; the mapped root was validated on target through flash, boot, deliberate corruption detection, and OTA replacement/rollback. |
| 6.d — Module signing | ✅ | `MODULE_SIG=y`, `MODULE_SIG_ALL=y`, and `MODULE_SIG_FORCE=y` on every kernel provider; on RZ/V2L the hand-installed Renesas modules use the shared signing include. |
| 6.e — IMA appraisal | 🟡 | Kernel `CONFIG_IMA=y`, `IMA_LSM_RULES=y`. No `ima_appraise=enforce` cmdline and no signed policy. |

### 7. Data minimisation

| Control | Status | Implementation |
|---|---|---|
| 7 — Process only what the declared function needs | ✅ | No telemetry. No phone-home. RAUC OTA is operator-triggered, not background-polled. |

### 8. Availability and resilience

| Control | Status | Implementation |
|---|---|---|
| 8.a — A/B rootfs with rollback | ✅ | RAUC `rootfs.0` + `rootfs.1` + boot-attempts counter in U-Boot env. |
| 8.b — Watchdog | ✅ | systemd runtime watchdog policy (`edge-watchdog`, `packagegroup-edge-base`) on every board; on RZ/V2L `watchdog@12800800` is started in U-Boot and kept by the kernel. |
| 8.c — Bounded log usage | ✅ | journald `SystemMaxUse=200M`, `SystemMaxFileSize=50M`. |

### 9. Denial-of-service resistance

| Control | Status | Implementation |
|---|---|---|
| 9.a — SYN cookies | ✅ | `net.ipv4.tcp_syncookies=1`. |
| 9.b — sshd rate limiting | ✅ | `MaxAuthTries 6`, `LoginGraceTime 30`, `MaxStartups 10:30:60`. |
| 9.c — journald rate limiting | ✅ | 1000 messages / 30s. |
| 9.d — fail2ban / brute-force lockout | 📅 | `meta-security` provides `fail2ban`; it is not in `packagegroup-edge-security`. |

### 10. Limiting the impact of a compromise

| Control | Status | Implementation |
|---|---|---|
| 10.a — Audit trail | ✅ | `edge-audit` — CIS L1 rules, immutable (`-e 2`). |
| 10.b — Tamper-evident logs | 🟡 | Integrity at rest is the journald structural hash chain, validated by `journalctl --verify`. FSS (`Seal=yes`) was upstream-deprecated in systemd 257 and is a no-op on wrynose (systemd 259); the alternative is a sealed remote aggregator. |
| 10.c — Privilege separation | ✅ | `root` not SSH-reachable; `devel` sudo with password on base and prod. |
| 10.d — Mandatory access control | 🟡 | SELinux MCS — `DISTRO_FEATURES += selinux`, `refpolicy-mcs` + `selinux-autorelabel`, `CONFIG_DEFAULT_SECURITY_SELINUX=y`, in the `CONFIG_LSM` stack; AppArmor explicitly off. Permissive baseline; `enforcing=1` validated on-board via controlled reboot, without a full AVC-clean policy set. |
| 10.e — Rootless-container isolation | ✅ | See [Accelerator isolation](#accelerator-isolation). HW-validated on both boards; zero AVC denials on RZ/V2L. |

### 11. Security-relevant records

| Control | Status | Implementation |
|---|---|---|
| 11.a — System events logged | ✅ | journald persistent + auditd. |
| 11.b — Build provenance | ✅ | `EDGE_BUILD_ID` (from `SOURCE_DATE_EPOCH`) in `/etc/buildinfo` (`edge-rootfs.bbclass`) on every image, and in the RAUC bundle manifest's `build` field (`RAUC_BUNDLE_BUILD`, `edge-bundle-common.inc`). |
| 11.c — Boot provenance | ✅ | On RZ/V2L the BL2 and U-Boot banners carry the boot marker (`EDGE_BOOT_VERSION` / `EDGE_BOOT_PROFILE` / `EDGE_BOOT_MACHINE`, TF-A and U-Boot bbappends); the Raspberry Pi 5 U-Boot carries no marker. `/etc/buildinfo` records the per-build id on every board. |

### 12. Secure updates

| Control | Status | Implementation |
|---|---|---|
| 12.a — Signed OTA bundles | ✅ | RAUC bundle signed by `edge-fit-dev` keychain. |
| 12.b — Atomic install + rollback | ✅ | A/B slot architecture. |
| 12.c — Update transport authenticity | ✅ | Two independent layers: the bundle signature is verified against the device keyring regardless of transport, and the transport itself is mutually authenticated — the device presents a client certificate and validates the server against its own CA. Both exercised in the same hardware-validated streaming install; signature verification happens over the stream, before any slot is written. |
| 12.d — Update without user interruption | ✅ | RAUC install while running; reboot to flip slot. |

### 13. Erasing data and settings

| Control | Status | Implementation |
|---|---|---|
| 13.a — Factory reset path | 📅 | No documented procedure. Needs an `edge-factory-reset` recipe + serial-console invocation. |

---

## Vulnerability handling process

Operational processes rather than image controls.

| Process | Status | Notes |
|---|---|---|
| Coordinated disclosure | 📅 | Needs `docs/security/SECURITY.md`, an intake address, and GitHub Security Advisories enabled. |
| Response times | 📅 | None by design for this reference implementation ([ADR-0013](../adr/0013-vulnerability-handling-cadence-and-release-gate.md)); response times are measured, not committed. A product built on the platform sets its own. |
| SBOM-driven patch path | 🟡 | SBOMs at every build; monitor and release loops with controlled report comparisons ([`VULN-HANDLING.md`](VULN-HANDLING.md) §6, §8). No CI gate diffs SBOMs across releases. |
| Security updates over a declared lifetime | 📅 | No support lifetime is declared. The kernel horizon is per board (ADR-0011): CIP SLTS on RZ/V2L implies ≥10y; the Raspberry Pi 5 follows the kernel.org longterm lifetime of its 6.18 line, years rather than a decade. |

---

## Workflow for adding controls

When implementing a planned or deferred item:

1. Move the row from 📅 / ⏸ → 🟡 (when infrastructure lands) → ✅ (when verifiable on-board).
2. Add the verification command to `docs/security/README.md` § "How to verify on-board".
3. If the control crosses tier boundaries (base vs dev vs prod), note the per-tier delta.
4. Cross-link the recipe / configuration file path so a reviewer can grep-jump.

When **removing** a control (e.g. trimming auditd rules for performance), drop the row to ⏸ with a one-sentence justification — never just delete.

# ADR-0009: RAUC encrypted-bundle recipient-key lifecycle

- Status: Accepted
- Date: 2026-09-02

## Context

RAUC `crypt` bundles protect payload confidentiality in two stages. A random
AES-256 key encrypts the bundle payload, then `rauc encrypt` CMS-envelopes the
signed manifest containing that key to one or more recipient certificates.
The target needs a corresponding recipient private key while it installs the
bundle. This key is distinct from the bundle-signing key and the HTTPS client
authentication key.

Introducing encrypted bundles cannot be an atomic fleet switch. Existing
devices accept only `verity` bundles and have no recipient private key. A
transition image must first provision the decryption configuration and widen
the accepted-format list while remaining installable as a `verity` bundle.

Key placement also determines the available recovery claims. A shared private
key stored in the rootfs is simple to deploy but is extractable and gives every
device the same confidentiality boundary. A key held by a PKCS#11 token backed
by a TPM, HSM, or TEE can be unique and non-exportable, but requires a device
provisioning and fleet-recipient workflow that does not yet exist here.

## Decision

### Separate the three OTA key roles

Bundle signing, HTTPS client authentication, and encrypted-bundle decryption
use independent keys and certificate lifecycles. A credential serving one role
is not reused for another.

### Use a staged format transition

Encrypted-bundle enablement follows this sequence:

1. A transition release enables bundle decryption in the image, accepts both
   `verity` and `crypt`, and is itself delivered as a `verity` bundle.
2. After that image is active, subsequent bundles use the `crypt` format and
   CMS-envelop the manifest before publication.
3. The device allowlist may be narrowed to `crypt` only after every supported
   recovery path can decrypt `crypt` bundles.

`RAUC_BUNDLE_FORMAT` is the authority for whether the build performs the
post-bundle encryption pass. The feature toggle controls the image-side key and
accepted-format configuration. This distinction permits the transition image
without asking RAUC to encrypt a non-`crypt` bundle.

### Keep the development baseline file-backed and explicit

The current development flow uses one shared recipient keypair. The private
key is installed in each image as `/etc/ota/bundle-decrypt.key`, owned by
`root:ota` with mode `0640`. The optional recipient certificate is installed as
`/etc/ota/bundle-decrypt.cert.pem`. The certificate speeds recipient lookup but
is not required for decryption.

This is a development and integration baseline, not a per-device revocation
design. The private key is protected only by rootfs access controls and runtime
dm-verity; offline image access or root compromise discloses it.

### Rotate with an overlap window

Planned rotation from recipient key K1 to K2 uses RAUC's multi-recipient CMS
support:

1. Generate K2 and include both K1 and K2 certificates in the build-host
   recipients PEM.
2. Publish a bundle decryptable by K1 and K2 whose image provisions K2.
3. Continue publishing for both recipients while the fleet migrates.
4. Remove K1 only after all devices and every retained A/B rollback slot use
   K2, or after policy declares the K1-only recovery paths unsupported.

The private key needed to install a bundle is the one in the currently running
slot. Updating the inactive slot does not update the rollback slot, so recipient
overlap is an A/B compatibility requirement, not merely a fleet rollout
convenience.

### Do not claim OTA recovery from a shared-key compromise

Routine rotation is possible over OTA, but secure recovery from compromise is
not. If K1 is known to an attacker, the attacker can decrypt the K1-addressed
transition bundle and extract a file-backed K2 from its rootfs payload. A
compromised shared key therefore requires trusted physical reprovisioning or a
separate recovery channel; rotating it inside a bundle protected by K1 does not
restore confidentiality.

### Use unique hardware-backed keys for production revocation

The production direction is one non-exportable recipient key per device,
accessed by RAUC through a PKCS#11 URI and backed by the platform TPM, HSM, or
OP-TEE secure storage. Corresponding public certificates belong in fleet
inventory. Bundles are encrypted per device or per managed recipient subset
outside the ordinary image build so one compromised device can be removed from
future recipient sets without disabling the rest of the fleet.

The existing PKCS#11 configuration surface is preparatory. This ADR does not
claim that the OP-TEE PKCS#11 Trusted Application, token provisioning, PIN
custody, recipient inventory, or per-device publication pipeline is complete.

## Rationale

- A two-release format transition preserves OTA reachability for devices that
  cannot yet accept or decrypt `crypt` bundles.
- Multi-recipient overlap makes planned rotation possible without reflashing
  and keeps old A/B slots usable during the migration window.
- Treating compromise recovery separately from planned rotation avoids a false
  security claim: wrapping a new rootfs key with a compromised old key only
  transfers the compromise.
- Independent key roles limit cross-protocol reuse and allow signing, transport
  authentication, and payload confidentiality to evolve separately.
- Unique hardware-backed keys reduce fleet blast radius and make recipient
  removal meaningful.

## Consequences

**Positive.** Encrypted bundles can be introduced without stranding existing
devices. Planned key rotation has an explicit overlap protocol. The current
shared-key implementation has a precise, limited claim, while the production
design supports per-device revocation and non-exportable keys.

**Negative.** The development key is present in every rootfs and compromise of
one copy compromises fleet bundle confidentiality. Rotation temporarily grows
the CMS recipient set and must account for both A/B slots. Per-device encryption
requires recipient inventory and publication infrastructure outside BitBake.
Hardware-backed keys add provisioning, token-access, recovery, and secure-state
rollback concerns.

## Scope and non-scope

This ADR covers confidentiality of RAUC bundle payloads and custody of the
recipient private key used during installation. It does not change bundle
signature trust, HTTPS client authentication, runtime rootfs dm-verity, writable
data encryption, or boot-chain anti-rollback. Those remain separate controls.

## Implementation status

- File-backed shared recipient key provisioning is wired behind
  `EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION`, on by default since 2026-09-04.
- The `verity` transition override and `verity crypt` device allowlist are
  wired.
- Build-time CMS encryption accepts a PEM containing multiple recipients;
  the rotation-overlap tooling to actually populate a second recipient
  without a manual `cat` is not implemented (task board).
- Encrypted bundles completed build and on-target validation 2026-09-04: a
  transition release (encryption-ready, format still `verity`) and a crypt
  release both installed over ordinary OTA on RZ/V2L hardware, booted, and
  passed `edge-verity-check.sh`/`edge-smoke-test.sh` on both slots. The
  gap this closed was a real defect, not just missing test coverage:
  `rauc encrypt`'s internal signature self-verify never loads
  `system.conf`, so it falls back to OpenSSL's default S/MIME-sign purpose
  check rather than this project's `check-purpose=codesign` policy, and
  the dev signer leaf's original codeSigning-only EKU failed that
  self-check unconditionally — no crypt bundle could have been built from
  the pre-fix PKI regardless of image content. Fixed by widening the leaf
  EKU to `codeSigning,emailProtection` (`scripts/rauc-init-certs.sh`).
- Hardware-backed per-device key provisioning and fleet publication are not
  implemented. The shared file-backed recipient key remains the only
  option, and the default flip makes that the default rather than an
  opt-in choice — every default image now carries the same key, so
  offline image access or a root compromise on any one device discloses it
  for the whole fleet. Acceptable for the current single-board tree; the
  "first production fleet" revisit trigger below still applies to closing
  this gap specifically, not to whether encryption is on.

## Revisit triggers

- The first production fleet requires encrypted bundles.
- OP-TEE or TPM PKCS#11 provisioning becomes available on a supported board.
- A fleet recipient inventory and per-device bundle publication service is
  selected.
- Recovery policy permits or forbids retaining an old recipient across A/B
  rollback slots.
- RAUC changes the `crypt` format or recipient-encryption model.

## References

- [RAUC bundle encryption](https://rauc.readthedocs.io/en/latest/advanced.html#bundle-encryption)
- [ADR-0003](0003-block-layer-integrity-confidentiality.md) — integrity, confidentiality, and sealed-key layer boundaries
- [ADR-0005](0005-image-class-ota-backend.md) — OTA backend abstraction
- [ADR-0008](0008-runtime-rootfs-verity.md) — runtime rootfs integrity and coordinated bundle contents
- [OTA updates](../dev/ota-updates.md) — operator workflow and configuration

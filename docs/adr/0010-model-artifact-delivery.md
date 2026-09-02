# ADR-0010: Model artifact format, schema contract and delivery trust boundary

- Status: Accepted
- Date: 2026-09-02

## Context

A compiled accelerator model reaches this platform by hand today. It is copied
into persistent storage, and the inference unit is guarded by a path condition
that simply skips when nothing is there. A freshly flashed device therefore
never infers until someone places files on it.

The device already carries three things that change at very different rates: the
firmware and root filesystem on a platform-release cadence, the inference
application on a code cadence, and the compiled model whenever it is retrained.
Only the first has a delivery channel — signed RAUC A/B bundles ([ADR-0005](0005-image-class-ota-backend.md)).
Pushing a model through that channel means every model change carries the risk,
the size and the reboot of a firmware update.

Three prior steps produced the evidence this record rests on. A real-input spike
established what a runner can and cannot learn from a compiled model directory.
A hardware verification pass established that the device's own stock container
tooling can enforce a signature policy over a model artifact and refuse the
negative cases. A host implementation pass then froze a schema and built the
artifact deterministically for three model classes.

What is *not* established is anything on the device beyond that verification
pass: there is no model store, no activation, no rollback, and no consumer of
the schema. This record is scoped to what is settled.

## Decision

### 1. Models get an update channel independent of firmware and application

The compiled model is delivered separately from the RAUC bundle and separately
from the inference application's container image. The three have different
cadences and, more importantly, different rollback domains: RAUC slot rollback
restores a root filesystem, and the model does not live there — it lives in
persistent storage that deliberately survives slot switches
([ADR-0004](0004-persistent-state-architecture.md)). A model rollback is
therefore a different mechanism from a firmware rollback, and coupling the two
would make each one lie about the other.

### 2. A model is a ModelPack-compatible OCI artifact, identified by manifest digest

The artifact is an OCI image manifest carrying an `artifactType`, with the model
payload in a typed layer:

| Role | Media type |
|---|---|
| artifactType | `application/vnd.cncf.model.manifest.v1+json` |
| config | `application/vnd.cncf.model.config.v1+json` |
| weight layer | `application/vnd.cncf.model.weight.v1.tar+gzip` |

**One** weight layer, holding the whole pack tree — the compiled model directory
and the label file. The board's stock BusyBox `tar` and `gunzip` were shown to
extract exactly this shape, and splitting the labels into a second raw layer
would move placement policy into a model store that does not exist yet.

`tar+gzip` rather than `tar+zstd`: the spec defines both, but the running image
has no zstd decompressor, and on a real model the size difference measured 2.7 %.
The choice is on merit, not only on availability.

The manifest digest is the model's identity everywhere downstream — approval,
retrieval, storage address and signature subject.

### 3. Config schema 1.0 is the local runner contract

The config blob carries only what a runner cannot read out of the compiled model
directory. Every field has a consumer that can check it:

| Field | Consumer |
|---|---|
| `schemaVersion` | the validator, and the future device-side loader |
| `name` | the model store's named reference |
| `version` | the `org.opencontainers.image.ref.name` tag in `index.json` |
| `accelerator` | device-side target selection; mirrored to a manifest annotation so a device can select before fetching the config |
| `model.directory` | the runner's model-load and pre-processing-load paths |
| `labels.path` | the index-to-name mapping every decoder class needs |
| `labels.count` | checked against the packed label file, and for classification against the compiled output element count |
| `decoder.class` | decoder dispatch; nothing in the model directory declares it |
| `decoder.*` | the decoder itself |

Decoder parameters are a **closed set per class**, not a free-form object:
classification takes `topK`; detection takes `scoreThreshold`, `iouThreshold`
and `maxDetections`, each bounded; segmentation takes none, because an argmax
over the class channel has nothing to tune. Unknown fields are rejected rather
than ignored, at every level, so a misspelling fails loudly instead of silently
disabling a setting.

`schemaVersion` is `MAJOR.MINOR`. A consumer accepts an equal MAJOR and a MINOR
no greater than its own; a MAJOR bump is breaking and an older consumer must
refuse it.

**Deliberate exclusions.** Input shape, layout, colour order, resize and
normalization are rejected by name, with a diagnostic saying why: they are
authoritative inside the compiled pre-processing object that actually executes,
and a second copy in metadata can disagree with the object that runs. Runtime and
compiler compatibility is also absent, and this is the harder call: the guardrail
is that a field is included only if the validator or the activation boundary can
enforce it. The compiled artifact carries a graph description with tensor shapes
and types but no compiler, runtime or ABI version, and the runtime's own
introspection is known unreliable — one of its describe-yourself calls is
unsupported and fails silently. An unenforceable version field would be
decoration that later readers would mistake for a check.

### 4. Construction is deterministic, so digest equality means byte equality

Canonical JSON for the config, manifest and index: sorted keys, no whitespace,
no trailing newline, non-finite numbers refused. Archive entries sorted, with
fixed ownership, fixed modes, and a fixed timestamp; gzip carries neither a name
nor a timestamp. The creation annotation is pinned rather than read from the
clock.

This is what makes "is this the model that was approved?" answerable. Without it
the digest changes on every rebuild and digest-pinning means nothing.

### 5. Authenticity and integrity are separate gates, with a model-specific key

Two checks answering two questions, both required, in this order: the signature
answers "did we approve these bytes", the content digest answers "did the bytes
arrive intact". Verification precedes extraction — an archive that has not been
authenticated is never handed to an extractor.

The model-signing key is **its own key**. It is not the RAUC bundle key, not the
FIT key, not the OTA mTLS client key, and not the RAUC crypt-bundle recipient key
of [ADR-0009](0009-rauc-encrypted-bundle-key-lifecycle.md) — that key decrypts
firmware bundles and has no relationship to model provenance. Different blast
radius, different rotation cadence, and reuse would let a model signature assert
firmware authenticity.

### 6. The artifact format does not provide activation or rollback

Nothing in the format switches which model is live. Activation belongs to a
content-addressed store on persistent data, holding an active and a previous
digest reference, and it is deferred. This ADR does not settle its layout, its
transaction, its garbage collection or its ordering against the persistence
services.

### 7. Evidence states are distinct and stay distinct

- **Hardware-verified prototype transport.** On the board, with a prototype
  artifact that predates schema 1.0: a signed artifact accepted, an unsigned one
  refused, a wrong-key one refused, and a corrupted one refused before
  extraction. The signing tool had to use its deprecated legacy attachment mode
  for the device's verifier to discover the signature.
- **Implemented host tooling.** Schema 1.0, a deterministic producer, and an
  inspector that trusts nothing the artifact says about itself, proven on three
  real compiled model classes with reproducible digests and zero round-trip
  differences in both directions.
- **Not done.** No pack built by the frozen contract has been signed or
  installed. Nothing on the device reads schema 1.0. There is no store.

Nothing in this record upgrades a claim from one state to another.

## Rationale

- Separating the model channel follows the cadence and the rollback domain, not
  the artifact size — compiled models vary by an order of magnitude and some are
  larger than a rootfs.
- Reusing OCI means reusing content addressing, registries, mirroring and
  signature tooling instead of inventing a format and its distribution.
- A single weight layer matches what the device was actually observed to extract,
  and defers a placement decision that belongs to the store.
- A closed, per-class parameter set makes an unknown key an error rather than a
  silent no-op, which is the failure mode a free-form decoder object invites.
- Excluding unenforceable metadata is the whole discipline: a field nothing
  checks reads to a later maintainer as a guarantee that does not exist.
- A model-specific signing key keeps a compromised model key from asserting
  anything about firmware.

## Consequences

**Positive.** A model can be approved by digest, reproduced byte-for-byte, and
distributed over ordinary registry infrastructure. The contract is enforced
mechanically rather than by convention, and a malformed or mistyped artifact
fails at the producer or the inspector rather than on the device. Firmware and
model rollback stay separate mechanisms, which is what they actually are.

**Negative.** A frozen schema is a compatibility surface: adding an enforceable
field later means a MINOR bump and a consumer that tolerates it. The deliberate
absence of runtime/compiler metadata means a model compiled against a future
incompatible runtime cannot be refused on metadata alone — the failure surfaces
at load time until an authoritative value exists. The device's verifier depends
on a signing mode its own tool marks deprecated. And the host tooling's
extraction guarantees do not run on the device; a store that does not invoke or
reproduce them inherits none of them.

## Scope and non-scope

**In scope:** the artifact format and its media types, the local config schema
and its compatibility rule, deterministic construction, and the trust boundary
separating model authenticity from firmware authenticity.

**Not in scope, and not settled by this record:** the on-device model store
layout and its transaction, activation and rollback semantics, garbage
collection, the registry product and its transport security and authentication,
the offline first-boot question, per-device or per-group encryption of model
artifacts, and the production multi-class runner. Those remain open, and this
ADR must not be read as having decided them.

## Implementation status

- Host tooling implemented in `scripts/modelpack/`: validator, deterministic
  producer, independent inspector and bidirectional round-trip comparison.
  Standard library only; no registry, network, key or build-system dependency.
- Schema 1.0 frozen, with example configs for all three decoder classes.
- The three-class gate passed on real compiled artifacts, each packed twice from
  independently created source copies.
- Signature policy and refusal behaviour verified on the board, against a
  prototype artifact from before the schema was frozen.
- Not implemented: any device-side consumer, the model store, activation,
  rollback, garbage collection, and signing of a frozen-contract artifact. The
  host extractor also has no output-size or entry-count ceiling, so
  decompression-bomb resistance is not among its guarantees.

## Revisit triggers

- The compiled artifact or its runtime gains an authoritative version value, at
  which point runtime/compiler compatibility becomes enforceable and earns a
  field.
- A fourth decoder class, which is a new closed parameter set and a MINOR bump.
- The model store's failure modes are tested, which is what would settle the
  activation and rollback decisions this record defers.
- The ModelPack specification changes its media types or its manifest shape.
- The device's verifier gains support for the signing tool's current attachment
  form, retiring the dependency on a deprecated mode.
- A second accelerator target, which turns the accelerator enum and its
  annotation into a real selection axis rather than a single value.

## References

- [ADR-0004](0004-persistent-state-architecture.md) — persistent state; where a
  model store would live and why it survives slot switches
- [ADR-0005](0005-image-class-ota-backend.md) — the firmware OTA boundary this
  channel is deliberately separate from
- [ADR-0009](0009-rauc-encrypted-bundle-key-lifecycle.md) — RAUC crypt-bundle
  recipient keys, which are unrelated to model signing
- [Model delivery](../drp-ai/model-delivery.md) — the measured evidence and the
  implemented contract
- [Model updates over the air](../drp-ai/model-ota-guide.md) — the architecture
  this record narrows to what is settled
- [ModelPack model specification](https://github.com/modelpack/model-spec) —
  `docs/spec.md` at commit `936ccad421f83d3f23126ce78fc913dac21c85f1`
- [OCI image specification](https://github.com/opencontainers/image-spec) —
  v1.1.1, including the image layout and its `imageLayoutVersion` `1.0.0`

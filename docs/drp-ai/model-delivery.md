# Model delivery — a signed-artifact prototype

**Status: prototype.** This documents a working, hardware-verified *transport* for
delivering a signed model to an EDGE AI OS device. For the architecture and the
concepts behind it — what each step protects against, and how the failure paths are
meant to behave — start with the [model update guide](model-ota-guide.md). It is **not** a completed model
update system — there is no model store, no activation, no rollback and no
automation. What is claimed here is exactly what was measured; the open work is
listed at the end.

## The problem: three clocks

A device carries three things that change at very different rates:

| component | changes when | today's delivery |
|---|---|---|
| firmware, kernel, runtime libraries | rarely — a platform release | RAUC A/B bundle, verified boot |
| inference application | occasionally — a code change | baked into the image |
| **compiled model** | **often — retraining, tuning** | **copied onto the device by hand** |

The mismatch is the problem. Shipping a new model today means either building and
installing a whole OS image, or placing files on the device manually. The first is
disproportionate; the second does not scale past one board and offers no guarantee
that what landed is what was intended.

A model needs its own update channel, with its own integrity guarantee.

## Current state

Models live under `/data/drpai`, placed by hand. The inference unit is guarded by a
`ConditionPathExists=` on that payload, so a freshly flashed device simply skips
inference and the smoke test reports the payload as absent. Nothing verifies that a
model came from an authorised source.

Persistence is already correct — `/data` survives A/B slot switches — so the
placement is durable. It is the *delivery* that is missing.

## Target architecture

- **Model as a signed OCI artifact.** Package the compiled model as a
  [ModelPack](https://github.com/CloudNativeAI/model-spec) artifact — an
  [OCI image manifest](https://github.com/opencontainers/image-spec) carrying an
  `artifactType`, with the model payload in typed layers. This reuses registries,
  content addressing and signature tooling instead of inventing a format.
- **Verification before extraction.** The device checks the signature against a
  trusted key under a default-reject policy, and the content digest before any
  archive is unpacked.
- **Content-addressed model store.** Models stored by digest, with a named
  reference pointing at the active one.
- **Atomic activation and rollback.** Switching models is a reference update;
  the previous digest is retained so reverting is a reference update too. Note
  that RAUC slot rollback covers the OS, not `/data` — model rollback is a separate
  mechanism.

## What has been verified

### Real input reaches the accelerator

The runtime does not describe its own input tensor: `GetInputInfo` is unsupported
in this runtime mode and returns an empty list, silently. The working path is
different and better:

- the compiled model directory ships its own DRP-AI **pre-processing object**;
- `PreRuntime` loads and executes it, producing a device-ready buffer;
- that buffer binds with `SetInput(0, ptr)`, which *is* supported.

**Design consequence:** input shape, resize and normalisation are already inside
the compiled artifact, so **the runner does not need them supplied as executable
settings** — a second authoritative copy could disagree with the object that
actually runs. What a runner cannot infer, and therefore what metadata has to
carry, is the output decoder class, labels, decoder parameters, and the
accelerator the model was compiled for.

The final schema is not fixed by this document. If it retains descriptive input
metadata, that metadata must be **validation-only** — checked against the compiled
artifact rather than used to drive execution.

Verified by classifying a known image on-device with two different models through
one unmodified binary, and cross-checking the result against the original ONNX run
off-target on a host with ONNX Runtime. **The ordered top five matched.**
Probability values differed between the two runs; this experiment did not isolate
the reason, so the agreement claimed here is ordering, not magnitude.

### A signed artifact is accepted, and bad ones are refused

Using the container tooling already present in the image, under a policy that
rejects everything by default with a single scoped exception for the model
repository:

| case | exit | result |
|---|---|---|
| correctly signed, trusted key | **0** | accepted |
| no signature | **1** | `a signature was required, but no signature exists` |
| signed with an untrusted key | **1** | `cryptographic signature verification failed: invalid signature` |
| corrupted content | **1** | digest mismatch, refused **before** extraction |

The first three rows are the signature-policy matrix, and three *distinct* failure
reasons is what makes the acceptance meaningful — a verification path that has
never refused anything is unproven.

The fourth row is a separate property. It was produced by taking a local copy of
the already-accepted artifact, altering one byte in its layer, and asking the tool
to copy it: content-address verification rejected the digest mismatch before
extracting anything. That case exercises content integrity, **not** the signature
policy, and should not be read as a fourth signature outcome.

The accepted artifact was then extracted and compared file-by-file against its
source — every path and digest identical — and the extracted model produced the
expected inference result.

The device's own installed policy file was never modified; the test policy, public
key and registry configuration were supplied at invocation time.

### Reproducibility

Two separate claims, both checked, and worth keeping separate:

- **Compiler reproducibility** — compiling the same source model twice produced
  byte-identical output, matching a previously deployed copy.
- **Packaging reproducibility** — packing the same tree twice produced identical
  layers and, with the creation timestamp annotation pinned, identical manifests.

This matters because a model is identified by its digest. If the digest changed on
every rebuild, "is this the model that was approved?" would be unanswerable.

## Constraints found by doing it

**The signature must use the legacy attachment layout.** With **Cosign 3.1.2 as
tested**, the default attachment form is not discovered by the image's verifier,
and verification then fails as *"no signature exists"* — indistinguishable from an
unsigned artifact. Signing in that tool's older, explicitly-selected attachment
mode produces the form the verifier does find. That mode is marked deprecated
upstream, which makes it the standing risk in the "no new software on the device"
approach. Other signing tools and later versions were not tested.

A media-type rewrite of the signature manifest was investigated as a further
compatibility step and found to be **unnecessary**: the attachment already
declares the expected media type, and the rewrite altered only JSON
serialization.

**gzip, not zstd.** The planned zstd-compressed layer verified and transferred
correctly but could not be extracted — the image has no zstd command-line tool. The
same tree repacked with gzip worked end to end. On a real model the size difference
was 2.7 %, so gzip is the better choice on merit rather than a workaround:
compiled accelerator weights are dense and leave little for a stronger compressor.

**The tested verifier upgrade did not help.** One newer verifier version was built
and run on the device: it failed to discover the modern attachment exactly as the
shipped version does, and additionally rejected the image's registry configuration
file format. That is a result about *that* version, not a general claim — a future
release may well change the discovery behaviour. On this evidence the shipped
version is the one to keep.

**The test registry was plain HTTP on an isolated link.** It provided no
confidentiality and no authentication. It was a feasibility transport for the
experiment only, torn down afterwards, and is explicitly **not** a production
registry choice.

## What this is not

This is a **ModelPack-format signed-delivery prototype**. It demonstrates that a
signed model artifact can travel to the device, be verified by software already
installed, be refused when it should be, and produce a correct result.

It is not a model update implementation. Still to be decided or built:

- **Production artifact schema** — the config fields, frozen and versioned.
- **Hostile-archive-safe extraction** — the prototype extraction is not hardened
  against path traversal, symlink escape, or decompression bombs.
- **Registry choice** — including transport security and authentication.
- **Model store lifecycle** — layout, fetch, garbage collection, ordering against
  the persistence services.
- **Atomic activation and rollback** — including behaviour when a model is absent
  or fails to load.
- **Production decoders** — detection and segmentation output decoding; only
  classification is implemented, and only as a recon tool.
- **Workload integration** — the inference unit currently names a fixed payload
  path rather than resolving a model by digest.
- **Fresh-device validation** — a newly flashed device reaching a running
  inference with no hand-placed files.

## See also

- [Model updates over the air — a guide](model-ota-guide.md) — the architecture and
  concepts, for readers new to OCI artifacts and model delivery
- [DRP-AI on EDGE AI OS](README.md) — platform overview and status
- [Compiling models](compiling-models.md) — producing a DRP-AI artifact
- [Benchmarking models](benchmarking-models.md) — measuring one on hardware
- [OTA updates](../dev/ota-updates.md) — the firmware update channel this one is
  deliberately separate from
- [ModelPack specification](https://github.com/CloudNativeAI/model-spec) ·
  [OCI image spec](https://github.com/opencontainers/image-spec) ·
  [Sigstore](https://www.sigstore.dev/)

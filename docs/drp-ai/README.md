# DRP-AI on EDGE AI OS

**Container-native inference on the Renesas RZ/V2L accelerator.**

A ResNet-18 classifier auto-starts at boot inside a **rootless Podman container**,
executes on the **DRP-AI** accelerator in **~28 ms**, and never touches an interactive
login or a graphical session — on a hardened, RAUC A/B, OTA-updatable platform.

![EDGE AI OS — RZ/V2L DRP-AI: author and export a model to ONNX, compile it on the build host, deploy the compiled artifact to persistent /data on the device, and run it in a rootless container on the DRP-AI NPU.](diagrams/rzv2l-drpai-pipeline.svg)

> **Why this exists.** The vendor's reference path for DRP-AI is a Weston/GUI demo, run
> as **root**, on a vendor BSP image — fine for a first look at the silicon, not what
> you ship. This is the other half: the accelerator as a **maintained, least-privilege
> service** on a platform built for long-lived edge devices.

## At a glance

| | |
|---|---|
| **Demonstrates** | ResNet-18 classifier · **~28 ms** on the accelerator (vs. seconds on CPU) |
| **Runs as** | rootless Podman container → systemd Quadlet → dedicated `nologin` principal (`edge-ctr`) |
| **Privilege** | no root, no `--privileged` — device access by `render`-group membership |
| **Boot** | starts automatically once a model payload is present; the payload persists across OTA slot switches |
| **Kernel** | linux-cip 6.12 (CIP Super-LTS, [ADR-0001](../adr/0001-kernel-base.md)) |
| **Status** | validated on hardware under **permissive** SELinux — [details](#status--roadmap) |

**What you need to reproduce it** — the split that shapes the whole integration:

| | Components | How you get them |
|---|---|---|
| **Public — in-tree recipes** | DRP-AI driver · TVM/MERA runtime · `u-dma-buf` · mmngr · the inference app | fetched from public sources, pinned by commit — nothing to obtain |
| **Vendor — host-only** | AI SDK: model compiler / translator · cross-SDK | free download from the Renesas portal; used on the build host, never shipped |

A compiled model is *produced with* the vendor host tools, but the artifact and the
on-device runtime that runs it are the public, redistributable pieces.

## Architecture — how the pieces fit

Four things live on the device: a **driver** exposing the accelerator, a **buffer
path** to feed it, a **runtime** to load compiled models, and an **app** to tie it
together.

- **Driver** — the DRP-AI chardev (`/dev/drpai0`), forward-ported to linux-cip 6.12.
  Source: **[umair-as/rzv2l-drpai-driver](https://github.com/umair-as/rzv2l-drpai-driver)**,
  fetched by `kernel-module-drpai`. *How the port was done → [port-notes.md](port-notes.md).*
- **Runtime + app** — `drpai-tvm-runtime` (Renesas' Apache-2.0 MERA/TVM libraries)
  executes compiled models; `drpai-tvm-app` is the sample classifier, built as a
  bitbake recipe so its ABI matches the rootfs. *Packaging details →
  [integration-notes.md](integration-notes.md).*
- **Buffers** — the driver is a control plane, **not** a buffer engine; the tensors
  live in three reserved DDR regions (`drp_reserved` 512 MiB, `image_buf`/udmabuf
  64 MiB, mmngr 128 MiB). *Deep dive → [integration-notes.md](integration-notes.md).*

### Container-native identity

This is where the integration diverges from the reference flow, and where the design
value sits. Instead of the app running as root in a desktop session, the workload is a
**rootless Podman container**, declared as a **systemd Quadlet**, under a **dedicated,
non-interactive service principal `edge-ctr`**:

- **`nologin`** — exists only to run containers; not a login surface
- **Pinned UID/GID** — the same principal across every build and device (audit-ready)
- **Own `subuid`/`subgid`** — deterministic, isolated rootless namespace mapping
- **Linger by design** — its systemd user instance (and its containers) exist without
  anyone logging in
- **State on `/data`** — home and container storage survive OTA slot switches
  ([ADR-0004](../adr/0004-persistent-state-architecture.md))
- **`render`-group member** — earns accelerator-node access with no elevation

Device passthrough carries `/dev/drpai0` + `/dev/udmabuf0` into the unprivileged
container with `GroupAdd=keep-groups` — no `--privileged`, no root. The whole boot
chain, no interactive login anywhere in it:

```mermaid
flowchart TB
    boot(["boot"]) --> mgr["user@608 manager starts<br/>edge-ctr · lingering · nologin"]
    mgr --> qd["Quadlet → drpai-inference.service"]
    qd --> ctr["rootless Podman container<br/>GroupAdd=keep-groups carries render"]
    udev["udev 71-edge-drpai.rules"] -->|"sets root:render 0660"| dev["/dev/drpai0<br/>/dev/udmabuf0"]
    dev -->|AddDevice| ctr
    ctr --> inf["DRP-AI · 28.69 ms · → beagle"]
```

*The boot-ordering fix that makes the lingered manager reliable → [integration-notes.md](integration-notes.md).*

## Proof it's the accelerator

Two independent witnesses show it's the silicon, not a CPU fallback dressed up as one:

1. **Latency** — the same network on CPU alone is on the order of *seconds*; ~28 ms is
   two orders of magnitude faster. Only the hardware path reaches it.
2. **The interrupt counter** — the DRP-AI block's AI-MAC completion counter in
   `/proc/interrupts` advances a fixed amount **per inference run** and stays put when
   nothing runs. Software can't move that counter; only the silicon raising the IRQ can.

Both hold **through the container** — the rootless run produces the same timing and the
same interrupt activity as a native run.

## Board-agnostic by construction

The whole stack is gated behind one feature switch and a machine guard. DRP-AI is
RZ/V2L-specific SoC IP, but the *structure* around it — a feature-gated accelerator
packagegroup, a dedicated rootless principal, a Quadlet workload, device passthrough by
group membership — is not Renesas-specific. **The accelerator is the changeable part;
the container-native, least-privilege, OTA-aware delivery is the durable part.**

## Reproduce & evaluate

- **Build it** — `make dev AI=1 VIRT=1` for `smarc-rzv2l` (`AI=1` adds the DRP-AI
  stack, `VIRT=1` the container runtime the Quadlet needs). A freshly flashed device
  boots with an empty `/data` and therefore **no model payload**, so nothing infers
  until one is placed at `/data/drpai` — the inference unit's
  `ConditionPathExists=` skips cleanly and the smoke test reports it. Automatic
  model delivery is roadmap work, not a shipped feature.
- **Compile your own model** → [compiling-models.md](compiling-models.md) — the
  host-side container flow (ONNX → DRP-AI artifact).
- **Measure any model on the NPU** → [benchmarking-models.md](benchmarking-models.md) —
  the `drpai-runner` benchmark, latency + NPU-vs-CPU split.
- **Understand model updates** → [model-ota-guide.md](model-ota-guide.md) — the
  architecture of model delivery, for readers new to OCI artifacts and ModelPack.
- **Deliver a model to the device** → [model-delivery.md](model-delivery.md) — a
  signed-artifact prototype: what is verified on hardware today, and what a real
  model update system still needs.
- **Go deeper** → [port-notes.md](port-notes.md) (driver port) ·
  [integration-notes.md](integration-notes.md) (runtime, buffers, lifecycle) ·
  [ADRs](../adr/).

## Status & roadmap

Stated honestly — the value of these docs depends on it.

**✅ Validated on hardware (permissive SELinux)** — driver builds and binds on
linux-cip 6.12 (`/dev/drpai0` present, accelerator confirmed via the interrupt
witness); runtime + app run natively and rootless; all three buffer regions in use;
rootless inference starts at boot under the dedicated principal, end-to-end, subject
to the intermittent race noted below.
Re-validated unchanged after three platform changes it predates: the CIP kernel
bump to 6.12.59-cip14, a **dm-verity read-only rootfs**, and **enforced kernel
module signing** — native 32.75 ms and containerized 28.54 ms, both in the proven
band. Validated from a fresh full image build and reflash, not only as deployed.

**⚠️ One known defect** — an **intermittent boot race** in `logind` linger
enumeration (`Couldn't add lingering user`, `ESRCH`): when it hits, the principal's
user manager does not come up, so the inference unit does not run. It self-heals on
the next boot. It has been observed both after an OTA and on an ordinary reboot into
an already-good slot, so it is **not** specific to the update path, and boots that
succeed do not establish that a given path is immune. The root cause is not yet
established — in particular, a plausible SELinux-labeling explanation was checked and
did not hold up (the linger directory carries the correct type, the mode was
permissive, and no relevant denial was recorded), so that repair is tracked
separately as its own correctness issue.

**⏭ Next, not done** — **SELinux enforcing** (needs a device-label policy for the
accelerator nodes and correct labels on the persistent state; not claimed as
achieved); the **linger race** above; and **model delivery** — the model is still
placed on `/data` by hand, so a freshly flashed device is not yet self-contained.

**🧭 Roadmap** — a reproducible model-compile environment; a baked, trust-pinned
container base image; and a digest-addressed, signature-verified model artifact
delivered independently of the firmware, replacing the hand-placed payload. The
delivery half now has a hardware-verified prototype — signed artifact accepted,
unsigned/wrong-key/corrupted refused — with the store and activation lifecycle
still to build: [model-delivery.md](model-delivery.md).

---

*This document describes method and architecture. It contains no vendor proprietary
material; the AI SDK, model translator, and GPU/codec libraries are obtained separately
under Renesas' own terms and are not part of this project.*

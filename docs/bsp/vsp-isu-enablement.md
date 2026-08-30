# Enabling VSP hardware convert/scale on RZ/V2L (the ISU node)

This note records how the RZ/V2L Video Signal Processor mem-to-mem path
(`vspmfilter` in GStreamer) was brought up, and the device-tree mistakes
that each fail in exactly the same, hard-to-diagnose way. It exists so the
next person enabling a VSP/ISU pipeline does not relearn it.

## The symptom and the cause

`vspmfilter` is the GStreamer element that performs colour-space conversion
and scaling on Renesas hardware (e.g. camera UYVY → NV12, with a resize).
On this platform it failed at runtime with `vspm: Invalid channel
use_ch=0xffffffff`: the plugin loaded and the pipeline reached PLAYING, but
the VSP manager never handed out a hardware channel.

The cause was upstream omission, not a bug in our stack. On RZ/V2L the VSP
mem-to-mem work is done by the **ISU (Image Scaling Unit)**, driven by the
out-of-tree `vspm-isu` platform driver (`compatible = "renesas,isum"`). The
RZ/V2L SoC device tree does **not** declare an ISU node, even though the
near-identical RZ/G2L SoC device tree does, and the silicon is the same.
With no node, `vspm-isu` binds nothing, so `vspmfilter`'s VSP core has no
channel to allocate. The fix is to declare the node; this repo carries it
as a board DTS patch (`0008-arm64-dts-rzv2l-smarc-add-isu-node.patch`).

A red herring worth dispelling: the mainline `vsp1` driver owns the display
VSP (`vsp@10870000`) and is **not** in conflict here — the ISU is a separate
register block at a different address. Binding the ISU does not contend with
the display path.

## What the node must provide, and why

The ISU driver is not a thin clock shim; its probe consumes real resources.
A correct node therefore needs all of:

- **Parent `&soc`** with a unit-address — it is a memory-mapped device, not a
  bare virtual node. (The `vspm_if` interface node has no `reg` and lives at
  the root; the ISU does have `reg` and belongs under `&soc`.)
- **`reg`** — the driver maps the ISU register bank via
  `platform_get_resource(IORESOURCE_MEM)` + `ioremap`. Omit it and probe
  fails at "failed to get resource of ISU".
- **`interrupts`** — the driver requests the ISU interrupt(s); the node
  declares the four ISU sources.
- **`clocks` / `clock-names` (`isu_aclk`, `isu_pclk`)**, **`resets`**, and
  **`power-domains`** — standard CPG wiring; `isu_aclk` is fetched by name.
- **`renesas,#rpf`, `renesas,#wpf`, `renesas,has-rs`, `renesas,#ch`** — the
  ISU topology (one read pixel formatter, one write pixel formatter, a
  resize unit, channel 0), read by the driver to size its internal state.

## Three mistakes that all produce `0xffffffff`

These are recorded because each one *looks* plausible and fails identically
to a correct-but-unsupported node — a wrong node makes a negative test
impossible to interpret:

1. **Root placement instead of `&soc`** — a node without the `reg`/parent the
   probe expects never binds.
2. **Missing `reg`** — `platform_get_resource` returns nothing; probe aborts.
3. **Wrong interrupt numbers** — the driver requests the wrong line. The
   manual's interrupt list and the device-tree `GIC_SPI` numbers are easy to
   read off-by-one; the safe method is to calibrate against an in-tree node
   whose interrupt is already known (here, the display VSP and DU nodes) and
   confirm the ISU sits where the manual places it relative to them. Doing
   this caught a one-line off-by-one before it shipped.

## How it was validated

The node was authored from two primary sources, never from inference: the
**RZ/V2L hardware manual (`r01uh0936`, section 36, Image Scaling Unit)** for
the register base, interrupt assignment, and clock/reset identity, and the
**in-tree RZ/G2L sibling node** (`r9a07g044.dtsi`) as a known-good template,
with the clock/reset macros translated to their V2L equivalents.

Result, proven on hardware from a clean boot: `vspm-isu` auto-binds the ISU
device, and the canonical capture pipeline

```
v4l2src device=/dev/video0 io-mode=mmap ! \
  video/x-raw,format=UYVY,width=1280,height=960 ! \
  vspmfilter dmabuf-use=true ! \
  video/x-raw,format=NV12,width=720,height=480 ! fakesink
```

runs to clean EOS with no invalid-channel errors. The captured NV12 output
carries a hardware DMA stride (wider than the visible width), which is the
fingerprint that the ISU genuinely processed the frame rather than a
software element silently substituting.

Re-confirmed on the CIP 6.12.59-cip14 kernel: plain CSI capture passes, the
camera-to-VSP path passes with no kernel errors, the ISU is bound, and a captured
NV12 frame is 529920 bytes — the expected 736-byte stride. MIPI camera to HDMI
preview passes on the same boot, so the chain is proven end to end from sensor to
display.

**Run the sensor/CRU alignment first.** The OV5645 comes up at 1280x960 while the
CSI-2 and CRU sub-devices default to 320x240. Without aligning them, `v4l2src`
fails with a broken pipe — a format mismatch, not a VSP fault.
`/usr/libexec/edge-ov5645-init.sh` (from the `edge-ov5645-init` recipe) performs
the alignment; anything automating this path runs it before streaming.

## Caveats for downstream use

- **`vspmfilter` requires root.** `/dev/rgnmm` and `/dev/vspm_if` are
  `0600 root:root`, so the element is invisible to a rootless principal. The
  container principal is also not a member of `video`, which puts `/dev/video0`
  out of reach as well. Making the media path usable inside the rootless inference
  container needs a udev rule (mode plus a group the principal joins) and that
  group membership — not a switch to a privileged principal. The accelerator nodes
  already work this way, so the pattern is established rather than speculative.
- **Modules ship with the kernel.** A kernel patch bumps the build-hash in the
  kernel version string, so the matching `/lib/modules/<version>/` must be
  deployed alongside the FIT. A full image or RAUC OTA bundles both; a
  FIT-only deploy leaves every out-of-tree module (VSP and DRP-AI alike)
  unloadable. See the BSP workflow contract, Deploy phase.
- **It is FOSS.** `vspmfilter` is GPL-2.0 and the VSP/MMNGR stack is part of
  the vendor BSP; none of this depends on the proprietary graphics/codec
  layers.

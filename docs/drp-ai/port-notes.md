# Porting the DRP-AI driver to linux-cip 6.12

Notes on forward-porting the Renesas DRP-AI kernel driver from its **6.1** baseline
to the **linux-cip 6.12** the platform standardises on, and on how the driver is
sourced. Orientation for this integration lives in the [README](README.md); this is
the how.

Driver source: **[github.com/umair-as/rzv2l-drpai-driver](https://github.com/umair-as/rzv2l-drpai-driver)**
(GPL-2.0), fetched by the `kernel-module-drpai` recipe, pinned by commit.

## Why the port was small

The naive reading of a 6.1→6.12 port is grim: DRP-AI moves large tensors, so it
sounds like chasing four releases of dma-buf / DMA-API churn — a rewrite. That reading
is wrong, and the reason is the whole point:

> **The DRP-AI driver is a control-plane character device, not a buffer engine.**
> `/dev/drpai0` configures the accelerator, kicks off inference, and reports
> completion. It does **not** own the bulk data path — model tensors never `mmap`
> through the driver; they live in separate memory regions (see the buffer
> architecture in the [integration notes](integration-notes.md)). So the dma-buf churn
> that dominates other drivers' forward-ports simply isn't in this one's surface.

## The API drift — five small fixes

Ordinary drift, version-guarded with `LINUX_VERSION_CODE` so the same source still
builds against 6.1:

- `class_create()` dropped its `owner` argument (6.4)
- `DEFINE_SEMAPHORE()` gained a count argument (6.4)
- `platform_driver`'s `.remove` became `void`-returning (6.11)
- `<linux/vmalloc.h>` stopped being transitively included
- a `const static` → `static const` ordering nit the newer compiler rejects

None of it touches the accelerator logic.

## The one real wall — a two-line kernel patch

> The driver does cache maintenance with the arm64 point-of-coherency helpers
> `dcache_clean_inval_poc()` / `dcache_inval_poc()`. On 6.12 these are **not exported
> to modules** — an in-tree driver calls them freely, an out-of-tree one fails
> `modpost` with undefined symbols. **This is why the vendor ships DRP-AI in-tree.**

We keep the driver out-of-tree (provenance below), so the fix is a **two-line kernel
patch** exporting those two symbols (`EXPORT_SYMBOL_GPL`), carried as a board patch
alongside the device-tree work. That patch — not the API drift — was the real cost of
the port. It is the difference between "port the driver" (small) and "rewrite the
buffer path" (imagined, never needed).

## Device tree

The DT side adds the `renesas,rzv2l-drpai` node — register banks, DRP-AI clocks,
reset, and the four completion interrupts — so the driver has something to bind.
Those interrupts are also the hardware witness that the accelerator actually ran
(see [README §Proof](README.md#proof-its-the-accelerator)).

## Provenance: fetched, not vendored

The V2L driver has no upstream git repo to track. The decision: **repackage the GPL
driver as a standalone public git repo and have the recipe *fetch* it, pinned by
commit — not vendor a copy into this tree.**

- **The driver is its own upstream.** A pinned external dependency keeps its history,
  licence, and provenance auditable, instead of melting a GPL drop into the platform.
- **The export patch stays a *kernel* patch.** The two-line cache-op export belongs to
  the kernel recipe, not the driver source — the driver stays pristine, the change
  stays visible.
- **Clean SBOM/CVE story.** A pinned module with a known licence and origin is a
  first-class line in the bill of materials, not an unattributed blob.

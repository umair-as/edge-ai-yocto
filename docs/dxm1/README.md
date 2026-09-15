# DEEPX DX-M1 on EDGE AI OS

The DX-M1 is a PCIe M.2 NPU. On EDGE AI OS it is the Raspberry Pi 5's
accelerator, composed by the machine fragment the way the RZ/V2L composes
DRP-AI: `make dev BOARD=raspberrypi5` builds it in, there is no separate
toggle. This set records what is in the tree and what has been proven on
hardware as of 2026-09-15; it does not cover model compilation or
benchmarking, which have not been done on this platform yet.

- [`README.md`](README.md) — this page: at a glance, architecture, proof, status.
- [`port-notes.md`](port-notes.md) — composing the vendor layer on wrynose and
  the kernel facts the card depends on.
- [`integration-notes.md`](integration-notes.md) — service identity, device
  policy, the rootless inference Quadlet, the payload contract.

## At a glance

| | |
|---|---|
| Board | Raspberry Pi 5, DX-M1 in the M.2 slot (PCIe Gen2 x1 to the BCM2712 root port `0001:00:00.0`) |
| Vendor layer | `meta-deepx-m1` at `703831e7` (walnascar branch), two wrynose patches under `kas/patches/meta-deepx-m1/` |
| Composition | `kas/accel/dxm1.yml`, included by `kas/machines/raspberrypi5.yml`; `EDGE_ACCEL = "dxm1"` |
| Kernel side | `dx_dma` (PCIe, single-MSI path for the brcmstb root port) and `dxrt_driver` (chardev) out-of-tree modules, signed like every other module |
| Userspace | `dx-rt` 3.4.1: `libdxrt`, `dxrtd`, `dxrt-cli`, `run_model` |
| Identity | system user and group `dxrt` (uid/gid 609); `/dev/dxrt0` is `root:dxrt 0660` |
| Rootless path | `edge-ctr` (uid 608) is in `dxrt`; the `dxm1-inference` Quadlet passes `/dev/dxrt0` into a container with `keep-groups` |
| Licence | every DEEPX package is `Proprietary`; images and bundles that carry them are marked `NOT-REDISTRIBUTABLE` beside the artifact |
| Card firmware | on the card, not in the image; the runtime refuses inference against a firmware older than it requires |

## Architecture — how the pieces fit

```
kas/machines/raspberrypi5.yml ─includes─▶ kas/accel/dxm1.yml
                                             │ EDGE_ACCEL=dxm1, EDGE_ACCEL_PROPRIETARY=1,
                                             │ EDGE_ACCEL_SUPPLEMENTARY_GROUPS=dxrt:edge-ctr
                                             ▼
edge-image.bbclass ─▶ packagegroup-edge-accel-dxm1
                        ├─ dx-driver        (vendor; bbappend: SRCREV pin, CONFIG_RPI_BUILD, vendor 0666 rule dropped)
                        ├─ dx-rt            (vendor; bbappend: SysV dxrt-init dropped)
                        ├─ edge-dxm1-runtime (dxrt user/group, 71-edge-dxm1.rules, hardened dxrtd.service)
                        └─ edge-dxm1-quadlet (/etc/containers/systemd/users/608/dxm1-inference.container)
```

Boot order on the board: the built-in PCIe bridge and its MIP MSI parent
probe at 0.5 s, the endpoint `1ff4:0000` is enumerated, udev loads
`dx_dma` by PCI modalias (no forced early load), `dxrt_driver` creates
`/dev/dxrt0`, `71-edge-dxm1.rules` sets `root:dxrt 0660`, and `dxrtd`
starts as `dxrt` (`ConditionPathExistsGlob=/dev/dxrt*`).

## Proof it is the accelerator

From the Raspberry Pi 5 on 2026-09-15 (image `20260915122250` and later,
`scratch/logs/rpi5-ontarget-checks*-20260915.txt`):

```
dx_dma_pcie 0001:01:00.0: RPi: forcing single MSI mode (brcmstb multi-MSI data misalignment)
dx_dma_pcie 0001:01:00.0: S-MSI allocation Success (1V, IRQ 152)
dx_dma_pcie 0001:01:00.0: [dx_dma_pcie_probe] Probe Done!!
dxrt_driver_cdev_init: 1 devices
152: ... MIP-MSI-PCI-MSI-0001:01:00.0   0 Edge      dx-dma_0        # /proc/interrupts
```

`dxrt-cli -s`, as root and as `edge-ctr`:

```
 * Device 0: M1, Accelerator type
 * RT Driver version   : v2.6.0
 * PCIe Driver version : v2.5.0
 * FW version          : v2.7.4
 * Memory : LPDDR5 5600 Mbps, 3.92GiB
 * Board  : M.2, Rev 1.0
 * PCIe   : Gen2 X1 [01:00:00]
NPU 0..2: voltage 750 mV, clock 1000 MHz, temperature 52'C
```

`dxrtd` runs as uid 609 (`/proc/<pid>/status`), `/dev/dxrt0` is
`crw-rw---- root dxrt`, and `id edge-ctr` lists `dxrt`. The smoke test's
accelerator section (`scripts/dev/edge-smoke-test.sh`, dispatched on
`EDGE_ACCEL`) checks each of these.

## Status

Proven on hardware: enumeration, MSI, driver probe, device node policy,
daemon identity, device identification from the rootless principal.

Not yet done: no inference payload has been staged on `/data/dxm1`, so the
`dxm1-inference` Quadlet has never run (it skips cleanly on
`ConditionPathExists=/data/dxm1/bin/run_model`); no model has been compiled
for the DX-M1 on this platform; no latency measured. The sibling project
that this port draws from staged `run_model` plus a model under
`/data/dxm1/{bin,lib,model}`; the same layout is what the Quadlet expects
here.

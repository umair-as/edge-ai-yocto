# DX-M1 integration notes

How the accelerator is exposed to userspace on EDGE AI OS, and why the
shape mirrors the DRP-AI integration (`docs/drp-ai/integration-notes.md`).

## Service identity and device policy (`edge-dxm1-runtime`)

- System user and group `dxrt`, static uid/gid 609
  (`meta-edge-distro/files/passwd`, `files/group`; `USERADD_ERROR_DYNAMIC`
  makes an unpinned id a build error).
- `/etc/udev/rules.d/71-edge-dxm1.rules`: `/dev/dxrt*` is `root:dxrt 0660`.
  The vendor's `99-dx-dma.rules` (world-writable node) is removed at
  `do_install` of `dx-driver`.
- `dxrtd.service` runs `/usr/bin/dxrtd` as `dxrt:dxrt` with
  `StateDirectory=dxrt`, `ProtectSystem=strict`, `NoNewPrivileges`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` and the usual
  namespace/personality restrictions; `ConditionPathExistsGlob=/dev/dxrt*`
  so a board without the card has no failed unit. It replaces the vendor's
  SysV `dxrt-init`.
- The daemon's IPC socket is created `0666` by `dxrtd` itself; the device
  node is what the group gates.

## Rootless inference path (`edge-dxm1-quadlet`)

`edge-ctr` (uid 608, the platform's rootless container principal) joins
`dxrt` at image assembly (`EDGE_ACCEL_SUPPLEMENTARY_GROUPS = "dxrt:edge-ctr"`
in `kas/accel/dxm1.yml`, applied by `edge-users.inc`), so a container it
starts can receive `/dev/dxrt0` with `keep-groups`. The Quadlet
`/etc/containers/systemd/users/608/dxm1-inference.container`:

```
[Unit]      After=data.mount   ConditionPathExists=/data/dxm1/bin/run_model
[Container] Image=docker.io/library/debian:trixie-slim  AddDevice=/dev/dxrt0
            GroupAdd=keep-groups  Volume=/data/dxm1:/dxm1:ro
            Exec=/dxm1/bin/run_model -m /dxm1/model/model.dxnn -b
[Service]   Type=oneshot
```

Payload contract: `/data/dxm1/bin/run_model`, `/data/dxm1/lib/` (runtime
libraries, `LD_LIBRARY_PATH`), `/data/dxm1/model/model.dxnn`. The payload
lives on `/data`, off the A/B rootfs, so a model update is not an OS
update. Nothing stages it yet: the Quadlet's condition is unmet on every
board so far and the unit is skipped, not failed.

The linger race that kept `user@608` from starting at boot is fixed at the
platform level (machine id restored before `systemd-userdbd` starts, see
`edge-persistence`); on 2026-09-15 `user@608` came up unaided on both
boards. On RZ/V2L that is what made the DRP-AI Quadlet run by itself; the
DX-M1 Quadlet will follow once a payload exists.

## Proprietary content

Every DEEPX package is `LICENSE = "Proprietary"` under a customer licence.
The recipes and the kas composition are publishable; an image or bundle
built from them is not. `EDGE_ACCEL_PROPRIETARY = "1"` makes
`edge-image.bbclass` write a `.NOT-REDISTRIBUTABLE` marker beside every
deployed image, and the artifact verifier checks for it.

## Checks

`scripts/dev/edge-smoke-test.sh` dispatches its accelerator section on
`EDGE_ACCEL` from `/etc/buildinfo`. For `dxm1` it checks: PCIe endpoint
`1ff4` present with Mem+/BusMaster+, ASPM off, `dx_dma` and `dxrt_driver`
loaded, `/dev/dxrt0` `root:dxrt 0660`, `dxrtd` active as `dxrt`,
`dxrt-cli -s` identifying the device, `edge-ctr` in `dxrt`, and whether the
Quadlet left a trace this boot when a payload is present. Build-side,
`scratch/rpi5/verify-rpi5-image.sh` checks the same facts in the rootfs
plus module signatures and the single-MSI path in `dx_dma.ko`.

## What differs from DRP-AI

DRP-AI is a memory-mapped SoC block driven through `/dev/drpai0` and
`/dev/udmabuf0` with a reserved carveout; the DX-M1 is a PCIe endpoint with
its own LPDDR5 and firmware, reached through one chardev and a daemon. The
integration shape is the same on purpose: a dedicated principal owns the
device, the operator login does not, and inference runs rootless with the
payload on `/data`.

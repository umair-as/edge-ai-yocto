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
  SysV `dxrt-init`. `Wants=systemd-udev-settle.service` alongside the
  matching `After=` — the `After=` alone does not pull that unit into the
  boot transaction, and a lost race against udev is a condition skip, not
  a failure, so `Restart=on-failure` would never recover it.
- `RuntimeDirectory=dxrt` plus `Environment=DXRT_DYNAMIC_IPC_ENDPOINT=/run/dxrt/ipc.sock`
  fix the daemon's IPC socket at a bind-mountable path. libdxrt's default
  lookup — an abstract `@dxrt_dynamic_ipc.sock` in the host's network
  namespace, then `/tmp/dxrt_dynamic_ipc.sock`, hidden by the unit's
  `PrivateTmp=yes` — is unreachable from a rootless Podman Quadlet in a
  private network namespace; the fixed endpoint is what the Quadlet binds
  in (below) and what host-side `dxrt-cli`/`run_model` need the same
  variable for, via `edge-dxrt-env.sh` (profile.d, shipped by
  `edge-dxm1-runtime`).

## Rootless inference path (`edge-dxm1-quadlet`)

`edge-ctr` (uid 608, the platform's rootless container principal) joins
`dxrt` at image assembly (`EDGE_ACCEL_SUPPLEMENTARY_GROUPS = "dxrt:edge-ctr"`
in `kas/accel/dxm1.yml`, applied by `edge-users.inc`), so a container it
starts can receive `/dev/dxrt0` with `keep-groups`. The Quadlet
`/etc/containers/systemd/users/608/dxm1-inference.container`:

```
[Unit]      After=data.mount   ConditionPathExists=/data/dxm1/bin/run_model
            StartLimitIntervalSec=600  StartLimitBurst=3
[Container] Image=docker.io/library/debian:trixie-slim  AddDevice=/dev/dxrt0
            GroupAdd=keep-groups  PodmanArgs=--pid=host
            Volume=/run/dxrt:/run/dxrt  Volume=/data/dxm1:/dxm1:ro
            WorkingDir=/tmp
            Environment=DXRT_DYNAMIC_IPC_ENDPOINT=/run/dxrt/ipc.sock
            Exec=/dxm1/bin/run_model -m /dxm1/model/model.dxnn -b
[Service]   Type=oneshot  Restart=on-failure  RestartSec=5s
            ExecStartPre=/usr/bin/timeout 60 /bin/sh -c 'until [ -S /run/dxrt/ipc.sock ]; do sleep 1; done'
```

`dxrtd` is a system unit and the Quadlet runs in `edge-ctr`'s user manager,
so `After=`/`Requires=` cannot order one against the other. `dxrtd.service`
is also `Type=simple`: it counts as started when the process is exec'd,
before `/run/dxrt/ipc.sock` exists. The `ExecStartPre` waits up to 60 s for
the socket; `Restart=on-failure` retries a start that still lost the race,
and the start limit ends the retries after three attempts, leaving the unit
`failed` for `edge-smoke-test.sh` to report.

`--pid=host` shares the host PID namespace: libdxrt's client liveness
check scans `/proc/*/cmdline` for `dxrtd`, which a private PID namespace
hides. `/run/dxrt` bind-mounted plus the matching
`DXRT_DYNAMIC_IPC_ENDPOINT` complete the reachability fix described above
— together they are what turns the vendor's default (`dxrt service is not
running`, error 264, in a private network + PID namespace) into a working
rootless client.

Payload contract: `/data/dxm1/bin/run_model`, `/data/dxm1/lib/` (runtime
libraries, `LD_LIBRARY_PATH`), `/data/dxm1/model/model.dxnn`. The payload
lives on `/data`, off the A/B rootfs, so a model update is not an OS
update. The image stages no payload itself; without one the Quadlet's
condition is unmet and the unit is skipped, not failed.

The linger race that kept `user@608` from starting at boot is fixed at the
platform level (machine id restored before `systemd-userdbd` starts, see
`edge-persistence`); `user@608` comes up unaided on both boards, and with a
payload staged the DX-M1 Quadlet runs unattended at boot the same way the
DRP-AI Quadlet does on RZ/V2L.

## Proprietary content

Every DEEPX package is `LICENSE = "Proprietary"` under a customer licence.
The recipes and the kas composition are publishable; an image or bundle
built from them is not. `EDGE_ACCEL_PROPRIETARY = "1"` makes
`edge-image.bbclass` write a `.NOT-REDISTRIBUTABLE` marker beside every
deployed image.

## Checks

`scripts/dev/edge-smoke-test.sh` selects its accelerator section from the
installed stack (`71-edge-dxm1.rules` for DX-M1). For DX-M1 it checks: PCIe endpoint
`1ff4` present with Mem+/BusMaster+, ASPM off, `dx_dma` and `dxrt_driver`
loaded, `/dev/dxrt0` `root:dxrt 0660`, `dxrtd` active as `dxrt`,
`/run/dxrt/ipc.sock` present, `dxrt-cli -s` identifying the device (with
the endpoint passed explicitly — a non-login `sudo` invocation cannot rely
on inherited environment), `edge-ctr` in `dxrt`, and whether the Quadlet
left a trace this boot when a payload is present. Build-side,
`edge_check_modules_signed` (image class) and the `dx-driver` bbappend's
single-MSI check cover module signatures and the `dx_dma.ko` build flag.

## What differs from DRP-AI

DRP-AI is a memory-mapped SoC block driven through `/dev/drpai0` and
`/dev/udmabuf0` with a reserved carveout; the DX-M1 is a PCIe endpoint with
its own LPDDR5 and firmware, reached through one chardev and a daemon. The
integration shape is the same on purpose: a dedicated principal owns the
device, the operator login does not, and inference runs rootless with the
payload on `/data`.

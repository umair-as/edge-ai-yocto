# Dev netboot (TFTP + NFS-root) runbook

This note covers the dev-only network-boot workflow: the board fetches the
signed FIT over TFTP and mounts its rootfs over NFS, replacing the
eject-reflash-reseat loop with a ~5-second sync. It is also the recommended
setup for **JTAG/kgdb labs** — an NFS rootfs survives a sustained core halt,
whereas an SD/eMMC rootfs wedges (see the JTAG section below).

Netboot is gated by `EDGE_DEV_NETBOOT` (the `NETBOOT=1` make flag →
`kas/dev-netboot.yml`). Prod images built without the flag carry zero netboot
surface. The default signed-FIT-from-mmc `bootcmd` is unchanged; `run netboot`
is operator-typed at the U-Boot prompt, and a power-cycle always falls back to
the signed mmc boot.

## One-time host setup

```sh
sudo ./scripts/dev/setup-tftp-nfs.sh        # tftpd-hpa + nfs-kernel-server
# override layout if your bench differs:
# SUBNET=192.168.0.0/24 TFTP_DIR=/srv/tftp NFS_ROOT=/srv/nfs/edge-image-dev \
#   sudo ./scripts/dev/setup-tftp-nfs.sh
```

Defaults: TFTP root `/srv/tftp` (FIT under `edge-fit-dev/`), NFS export
`/srv/nfs/edge-image-dev`, subnet `192.168.0.0/24`. The script is idempotent
and prints the host IP to use as `serverip`.

## Build a netboot-enabled image

```sh
make dev NETBOOT=1                 # dev image + netboot env macro
make dev NETBOOT=1 JTAG=1          # + JTAG/kgdb debug kernel (labs)
```

The kernel ships `ROOT_NFS`, `IP_PNP_DHCP`, `RAVB`, and `MICREL_PHY` built-in,
so NFS-root needs no kernel fragment. `eth0` is left unmanaged by
systemd-networkd (`10-eth0.network` `Unmanaged=yes`) so the kernel's `ip=dhcp`
NFS path on eth0 is undisturbed; `eth1` is the DHCP uplink.

## Per-board U-Boot env (once per board)

At the U-Boot prompt:

```
setenv ipaddr 192.168.0.232          # board's static IP
setenv serverip 192.168.0.10         # TFTP/NFS host
setenv netmask 255.255.255.0
setenv nfs_export /srv/nfs/edge-image-dev
saveenv
```

## Per-iteration loop

```sh
make dev NETBOOT=1                    # rebuild
make netboot-sync                     # = sudo scripts/dev/sync-nfs-rootfs.sh
```
Then on the board (U-Boot prompt):
```
run netboot
```

`run netboot` TFTPs `edge-fit-dev/fitImage` and boots with
`root=/dev/nfs nfsroot=${serverip}:${nfs_export},vers=3,nolock,tcp ip=dhcp`.
A TFTP-fetch failure falls through to the signed mmc `bootcmd` — no silent
downgrade; `bootm` still verifies the FIT signature regardless of byte source.

## JTAG / kgdb labs — why NFS-root

A JTAG halt freezes all CPUs for as long as the debugger holds them. With the
rootfs on SD/eMMC, the `renesas_sdhi` controller times out on any in-flight
write (`CMD25`/`CMD13` "timeout waiting for hardware interrupt") and the rootfs
wedges — the controller runs independently of the halted core, so disabling
the lockup detectors does not prevent it. An NFS rootfs has no such hardware
timeout: hard-mount RPCs pause and resume across the halt.

So for breakpoint/single-step beats (sustained halts), boot the JTAG image over
NFS:

```sh
make dev NETBOOT=1 JTAG=1
make netboot-sync
# board: run netboot, then halt/step freely over JTAG
```

Optional: append `maxcpus=1` to the netboot bootargs to also silence the
cross-CPU IPI soft-lockup on the unhalted core (the `jtag-debug.cfg` kernel
already compiles the detectors out, so this is belt-and-suspenders). Set it by
editing the `netboot` env var's `bootargs` string, or `setenv bootargs "... maxcpus=1"`
before `bootm`.

The gdb helper scripts (`lx-ps`, `lx-dmesg`, `lx-symbols`) need
`scripts/gdb/linux/constants.py`, which the JTAG build generates via
`make scripts_gdb` (see `linux-renesas_6.12.bbappend`); source
`${B}/scripts/gdb/vmlinux-gdb.py` in gdb. KASLR is compiled out in the JTAG
kernel, so `file vmlinux` + connect needs no offset.

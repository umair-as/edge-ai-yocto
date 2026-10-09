# Netboot — RZ/V2L

Board side of [netboot](README.md) on the RZ/V2L SMARC EVK. It is also the
recommended setup for JTAG/kgdb labs (below).

## Build

```sh
make dev NETBOOT=1                 # dev image + netboot env macro
make dev NETBOOT=1 JTAG=1          # + JTAG/kgdb debug kernel (labs)
```

The kernel has `ROOT_NFS`, `IP_PNP_DHCP`, `RAVB` and `MICREL_PHY` built in, so
NFS-root needs no kernel fragment. `eth0` is left unmanaged by systemd-networkd
(`10-eth0.network`, `Unmanaged=yes`) so the kernel's `ip=dhcp` NFS path on `eth0` is
undisturbed; `eth1` is the DHCP uplink.

`make netboot-sync` defaults to this board: `MACHINE=smarc-rzv2l`, deploy directory
`build/tmp/deploy/images/smarc-rzv2l/`.

## U-Boot env (once per board)

Flash the netboot-enabled image to the SD and boot it once. At the `=>` prompt (stop
autoboot with `edge` within 3 s):

```
=> setenv serverip <host-ip>          # printed by setup-tftp-nfs.sh
=> setenv nfs_export <nfs-export-path>
=> saveenv
=> boot
```

The values persist in the U-Boot env on the SD. On a network without DHCP for the
board, also set `ipaddr` and `netmask`.

## JTAG / kgdb labs — why NFS-root

A JTAG halt freezes all CPUs for as long as the debugger holds them. With the rootfs
on SD or eMMC, the `renesas_sdhi` controller times out on any in-flight write
(`CMD25`/`CMD13` "timeout waiting for hardware interrupt") and the rootfs wedges; the
controller runs independently of the halted core, so disabling the lockup detectors
does not prevent it. An NFS rootfs has no such hardware timeout: hard-mount RPCs pause
and resume across the halt. For breakpoint and single-step work, boot the JTAG image
over NFS:

```sh
make dev NETBOOT=1 JTAG=1
make netboot-sync
# board: run netboot, then halt/step freely over JTAG
```

Appending `maxcpus=1` to the netboot bootargs also silences the cross-CPU IPI
soft-lockup on the unhalted core (the `jtag-debug.cfg` kernel already compiles the
detectors out). Set it in the `netboot` env var's `bootargs` string, or
`setenv bootargs "... maxcpus=1"` before `bootm`.

The gdb helper scripts (`lx-ps`, `lx-dmesg`, `lx-symbols`) need
`scripts/gdb/linux/constants.py`, which the JTAG build generates via
`make scripts_gdb` (`linux-renesas_6.12.bbappend`); source
`${B}/scripts/gdb/vmlinux-gdb.py` in gdb. KASLR is compiled out in the JTAG kernel,
so `file vmlinux` plus connect needs no offset. Full lab setup:
[`../jtag/README.md`](../jtag/README.md).

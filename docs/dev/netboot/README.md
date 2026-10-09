# Netboot — TFTP + NFS-root for fast dev iteration

The board fetches the signed FIT over TFTP and mounts its rootfs over NFS, so an
iteration replaces the eject-reflash-reseat loop:

```
edit code → make dev NETBOOT=1 → make netboot-sync → reset board → run netboot
```

about 30 seconds per cycle against a few minutes of SD-card handling.

## Boards

| Board (`BOARD=`) | Netboot | Page |
|---|---|---|
| `rzv2l` | supported | [rzv2l.md](rzv2l.md) — U-Boot env, NICs, JTAG labs |
| `raspberrypi5` | not available: U-Boot is built with networking off (`edge-rpi5-net-off.cfg`); iterate with `make dev` plus a RAUC bundle ([ota-updates.md](../ota-updates.md)) | — |

## Security posture (the contract)

This is a **dev workflow only**. Five properties hold by construction:

1. **Default `bootcmd` is byte-for-byte unchanged.** Power-on always runs the
   signed-FIT mmc path. Netboot is the operator typing `run netboot` at the U-Boot
   prompt — never auto-invoked.
2. **`bootm` verifies the FIT signature regardless of byte source.** A FIT delivered
   over TFTP goes through the same signature gate as one read from mmc; an
   unauthorized FIT on the TFTP server is rejected at U-Boot.
3. **The `netboot` env macro ships only when `EDGE_DEV_NETBOOT=1`.**
   `make dev NETBOOT=1` (composing `kas/dev-netboot.yml`) appends it to
   `/etc/rauc-uboot-env.defaults`; other builds carry no netboot bytes.
4. **A TFTP fetch failure falls through to `run bootcmd`** (the signed mmc path).
   It never bricks and never silently downgrades the trust posture.
5. **`saveenv` is absent from the netboot path.** The `root=/dev/nfs` bootargs are
   kernel-cmdline-only and do not persist into the next mmc boot.

A release build never composes `kas/dev-netboot.yml` or sets `NETBOOT=1`.

## Requirements

- A Linux host where `tftpd-hpa` and `nfs-kernel-server` are installable
  (Debian/Ubuntu-class); the setup script installs them.
- Ethernet between board and host on the same L2 segment, with DHCP reaching the
  board.
- A static IP on the host, so the board's U-Boot env can pin `serverip`.

## Host setup (once)

```sh
./scripts/dev/setup-tftp-nfs.sh       # idempotent; prompts for sudo once
SUBNET=<subnet> NFS_ROOT=<nfs-export-path> ./scripts/dev/setup-tftp-nfs.sh   # other layouts
```

The script installs both services, creates the TFTP root (FIT under
`/srv/tftp/edge-fit-dev/`) and the NFS export root, writes a subnet-scoped
`/etc/exports` entry:

```
<nfs-export-path>  <subnet>(rw,sync,no_subtree_check,no_root_squash,no_acl)
```

reloads the exports, checks both services bound their ports, and prints the host IP
to set as `serverip` on the board. The export has **no `fsid=root`**: that flag
makes it the NFSv4 pseudo-root, and a v4 client given the full path in `nfsroot=`
then hangs silently.

Smoke test from the host, against its LAN IP (`127.0.0.1` is outside the subnet
rule, so mountd rejects `localhost`):

```sh
sudo timeout 5 mount -t nfs -o vers=3,nolock <host-ip>:<nfs-export-path> /mnt \
  && ls /mnt | head -5 && sudo umount /mnt
```

The board side is set once per board at its U-Boot prompt; see the board's page.

## The iteration loop

```sh
make dev NETBOOT=1
make netboot-sync
```

`make netboot-sync` runs `sudo ./scripts/dev/sync-nfs-rootfs.sh`, which takes the
newest `edge-image-dev-<machine>.rootfs-*.tar.gz` from the board's deploy directory
(`MACHINE`, `DEPLOY_DIR`; defaults on the board page), wipes the export, extracts the
tarball with `--numeric-owner --xattrs` so ownership and capabilities survive,
atomically replaces `/srv/tftp/edge-fit-dev/fitImage`, and re-exports
(`exportfs -ra`) so mountd's handle cache sees the new inodes. About 5 seconds.

On the board:

```
=> reset
(stop autoboot)
=> run netboot
```

## What `run netboot` does

```
netboot=setenv autoload no;
        setenv _edge_saved_serverip ${serverip};
        dhcp;
        setenv serverip ${_edge_saved_serverip};
        setenv _edge_saved_serverip;
        if tftp ${loadaddr} ${serverip}:edge-fit-dev/fitImage; then
            setenv bootargs "root=/dev/nfs rw nfsroot=${serverip}:${nfs_export},vers=3,nolock,tcp ip=dhcp earlycon";
            bootm ${loadaddr};
        else
            echo "[netboot] tftp ... failed; falling back to signed mmc boot";
            run bootcmd;
        fi
```

- **`serverip` save/restore.** `dhcp` overwrites `serverip` with the lease's
  `next-server`, usually the router, which has no TFTP. The macro restores the saved
  value and clears the temporary variable so it never reaches a `saveenv`.
- **`vers=3`.** The in-kernel NFS-root client mounts NFSv3 reliably in early init;
  an NFSv4 root mount can hang silently on an unusual export layout.
- **No `saveenv` after `setenv bootargs`.** The NFS bootargs are runtime-only; each
  `run netboot` rebuilds them from the env.

## Verifying a netboot

```sh
findmnt /
# TARGET SOURCE                            FSTYPE OPTIONS
# /      <host-ip>:<nfs-export-path>       nfs    ...vers=3...
```

`rauc status` shows `slot _external_ (?)`: there is no managed A/B slot when the
rootfs lives on NFS.

## Reverting to signed mmc boot

Power-cycle: autoboot runs `bootcmd` against the signed mmc image. The `netboot`
macro stays in the U-Boot env but only runs when typed. An image built without
`NETBOOT=1` has no macro (`EDGE_DEV_NETBOOT="0"`).

## Troubleshooting

- **`Loading: T T T ...` at TFTP**: `dhcp` clobbered `serverip` (an image with a
  macro that lacks the save/restore). Rebuild and reflash, or at the prompt:
  ```
  setenv serverip <host-ip>
  tftp ${loadaddr} ${serverip}:edge-fit-dev/fitImage
  setenv bootargs "root=/dev/nfs rw nfsroot=${serverip}:${nfs_export},vers=3,nolock,tcp ip=dhcp earlycon"
  bootm ${loadaddr}
  ```
- **Kernel hangs after `IP-Config: Complete` with `rootpath=` empty**: `nfs_export`
  is unset. `printenv nfs_export`; if it errors, `setenv nfs_export <nfs-export-path>`
  and `saveenv`.
- **Kernel hangs silently after `IP-Config: Complete`**: the export has `fsid=root`.
  Remove it from `/etc/exports` and `sudo exportfs -ra`.
- **`mount.nfs: access denied` against `localhost`**: test with the host's LAN IP.
- **Two boards on one NFS export** fight over a writable rootfs. Use one export per
  board.
- **`make netboot-sync` while a board boots from the export** can corrupt that boot.
  Sync between iterations.

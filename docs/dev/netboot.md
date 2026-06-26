# Netboot — TFTP + NFS-root for fast dev iteration

After one-time setup, the iteration loop is:

```
edit code → make dev NETBOOT=1 → make netboot-sync → reset board → run netboot
```

~30 seconds per cycle vs ~3 minutes of physical SD-card handling.

## Security posture (the contract)

This is a **dev workflow only**. Five properties hold by construction:

1. **Default `bootcmd` is byte-for-byte unchanged.** Power-on always
   runs the signed-FIT mmc path. Netboot is the operator typing
   `run netboot` at the U-Boot prompt — never auto-invoked.
2. **`bootm` verifies the FIT signature regardless of byte source.**
   A FIT delivered via TFTP goes through the same `sha256,rsa2048`
   gate as one read from mmc. Unauthorized FITs on the TFTP server
   are rejected at U-Boot.
3. **The `netboot` env macro ships only when `EDGE_DEV_NETBOOT=1`.**
   `make dev NETBOOT=1` (or composing `kas/dev-netboot.yml`)
   appends it to `/etc/rauc-uboot-env.defaults`; otherwise prod
   builds carry zero netboot bytes.
4. **TFTP fetch failure falls through to `run bootcmd`** (the signed
   mmc path). Never bricks, never silently downgrades the trust
   posture.
5. **`saveenv` is deliberately absent from the netboot path.** The
   `root=/dev/nfs` bootargs are kernel-cmdline-only and don't
   persist into the next mmc boot.

Don't compose `kas/dev-netboot.yml` (or set `NETBOOT=1`) for a release
build.

## What you need

- A Linux host with `tftpd-hpa` + `nfs-kernel-server` installable
  (Debian/Ubuntu-class distro). The setup script handles install.
- Ethernet between the board and the host on the same L2 segment.
  DHCP must reach the board — your LAN's existing DHCP works; no
  dnsmasq required unless you're on a direct cable without one.
- A static IP on the host so the U-Boot env can pin `serverip`.

## One-time setup

### Host

Run the bootstrap script — it's idempotent and prompts for sudo once:

```sh
./scripts/dev/setup-tftp-nfs.sh
```

The script:

- Installs `tftpd-hpa` + `nfs-kernel-server` if missing.
- Creates `/srv/tftp/edge-fit-dev/` (TFTP root) and
  `<nfs-export-path>/` (NFS export root).
- Writes `/etc/exports` with subnet-scoped access:

  ```
  <nfs-export-path>  <subnet>(rw,sync,no_subtree_check,no_root_squash,no_acl)
  ```

  **No `fsid=root`** — that flag makes the export the NFSv4
  pseudo-root, which causes v4 clients to see it as `/` and silently
  hang when the kernel passes the full path in `nfsroot=`. Without
  it, both v3 and v4 clients reach the export at its actual path.
- Reloads exports, starts both services, sanity-checks they bound
  their respective ports.
- Prints the host's primary IP at the end — the value you'll set as
  `serverip` on the board.

Override via env if your bench layout differs:

```sh
SUBNET=<subnet> NFS_ROOT=<nfs-export-path> ./scripts/dev/setup-tftp-nfs.sh
```

Smoke test (run as yourself with `sudo`):

```sh
sudo timeout 5 mount -t nfs -o vers=3,nolock <host-ip>:<nfs-export-path> /mnt \
  && ls /mnt | head -5 && sudo umount /mnt
```

If that prints `bin boot dev etc home`, the host side is ready.

(Don't test against `localhost` — `127.0.0.1` is not in the
`<subnet>` allow rule, so mountd correctly rejects it.)

### Per-board (one-time at the U-Boot prompt)

Boot once with the netboot-enabled image flashed to SD:

```sh
make dev NETBOOT=1
# flash build/tmp/deploy/images/smarc-rzv2l/edge-image-dev-smarc-rzv2l.wic.zst
```

At the `=>` prompt (stop autoboot with `edge` within 3 s):

```
=> setenv serverip <host-ip>       # YOUR host's LAN IP
=> setenv nfs_export <nfs-export-path>
=> saveenv
=> boot
```

Persisted to U-Boot env on the SD card. Future netboots reuse these
values.

## The iteration loop

After each source edit on the host:

```sh
make dev NETBOOT=1
make netboot-sync
```

`make netboot-sync` runs `sudo ./scripts/dev/sync-nfs-rootfs.sh`,
which:

- Locates the newest
  `edge-image-dev-smarc-rzv2l.rootfs-*.tar.gz` under
  `build/tmp/deploy/images/smarc-rzv2l/`.
- Wipes `<nfs-export-path>/`.
- Extracts the tarball with `--numeric-owner --xattrs` so uid/gid
  and capabilities survive into the rootfs.
- Atomically replaces `/srv/tftp/edge-fit-dev/fitImage`.
- Re-exports (`exportfs -ra`) so mountd's handle cache picks up
  the inode changes.

~5 seconds end-to-end.

On the board, then:

```
=> reset
(stop autoboot with 'edge')
=> run netboot
```

## What `run netboot` does (and why it's shaped this way)

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

Three subtle bits worth knowing:

**1. `serverip` save/restore.** U-Boot's `dhcp` command overwrites
   `serverip` with the DHCP lease's `next-server` field. On consumer
   networks `next-server` is usually the DHCP server itself — your
   router, which has no TFTP. Without the save/restore, the operator's
   `setenv serverip <host>; saveenv` would be silently clobbered every
   `run netboot` and TFTP would hit the wrong host. The temp var
   `_edge_saved_serverip` is cleared after restore so it doesn't end
   up in a future `saveenv`.

**2. `vers=3` not `vers=4`.** The Linux kernel's in-kernel NFS-root
   client is more reliable on NFSv3 for early-init mount. NFSv4 root
   mount can hang silently if the server has any unusual export
   layout (e.g. an `fsid=root` flag — the setup script
   intentionally omits it). v3 is the canonical bench dev choice.

**3. No `saveenv` after `setenv bootargs`.** The `root=/dev/nfs`
   bootargs are runtime-only; persisting them would break the next
   mmc boot. Each `run netboot` rebuilds the bootargs from current
   env vars.

## Verifying you're actually on netboot

Once at the login prompt:

```sh
findmnt /
# TARGET SOURCE                                            FSTYPE OPTIONS
# /      <host-ip>:<nfs-export-path>             nfs    ...vers=3...
```

NFS source visible, `vers=3` confirmed → you're on netboot. RAUC will
show `slot _external_ (?)` — that's the correct response, not a bug.
There's no managed A/B slot when the rootfs lives on NFS.

## Reverting to signed mmc boot

Power-cycle. Autoboot runs `bootcmd` against the signed mmc image.
The `netboot` env macro persists in U-Boot env but only fires when
operator-typed.

To permanently strip the macro from a deployed image, rebuild without
`NETBOOT=1` — the `EDGE_DEV_NETBOOT` gate goes to `"0"` and the
macro line isn't appended to `/etc/rauc-uboot-env.defaults`.

## Troubleshooting

- **`Loading: T T T ...` at TFTP**: the `dhcp` command clobbered
  `serverip`. Means your image still has the old un-save/restored
  macro. Either rebuild + reflash, or at the U-Boot prompt:
  ```
  ctrl-C
  setenv serverip <host-ip>
  tftp ${loadaddr} ${serverip}:edge-fit-dev/fitImage
  setenv bootargs "root=/dev/nfs rw nfsroot=${serverip}:${nfs_export},vers=3,nolock,tcp ip=dhcp earlycon"
  bootm ${loadaddr}
  ```
- **Kernel hangs after `IP-Config: Complete` with `rootpath=` empty**:
  the env var `nfs_export` is undefined. `printenv nfs_export` at the
  U-Boot prompt; if it errors, `setenv nfs_export <nfs-export-path>`
  + `saveenv`.
- **Kernel hangs silently after `IP-Config: Complete`** (vs the
  `rootpath=` case above): exports have `fsid=root`. Remove that
  flag from `/etc/exports` + `sudo exportfs -ra`. Sanity-test:
  `sudo timeout 5 mount -t nfs -o vers=3,nolock <host-ip>:<nfs-export-path> /mnt`.
- **`mount.nfs: access denied`** when testing locally against
  `localhost`: `127.0.0.1` isn't in your `<subnet>` allow rule.
  Test using the host's LAN IP.
- **Two boards sharing one NFS export will fight** over writeable
  rootfs. Use one export per board, or shift to a read-only NFS +
  tmpfs overlay (deferred; not built yet — single-board case covers
  bench iteration).
- **`make netboot-sync` while a board is mid-boot from the NFS root**
  can corrupt that boot. Sync between iterations, not during one.

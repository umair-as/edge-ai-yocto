# Porting the DX-M1 stack to wrynose on the Raspberry Pi 5

What it took to compose DEEPX's `meta-deepx-m1` on Yocto 6.0 (wrynose)
with a mainline 6.18 kernel, and the kernel facts the card turned out to
depend on. Evidence: `scratch/rpi5/boot2-analysis-20260915.md`.

## Vendor layer: one branch, two patches

`meta-deepx-m1` is pinned at commit `703831e7` on its `walnascar` (Yocto
5.2) branch: one release away from wrynose, one `dx-driver` version, the
newest driver SRCREV. Neither upstream branch is wrynose-compatible on its
own, so kas applies two patches from `kas/patches/meta-deepx-m1/` at
checkout:

- `0001-layer.conf-declare-wrynose-compatibility.patch` —
  `LAYERSERIES_COMPAT` cannot be amended from `local.conf` (bitbake reads
  it right after parsing each `layer.conf` and deletes the variable), so
  the layer itself is patched.
- `0002-dx-rt-no-build-isolation.patch` — `dx-rt`'s `do_install` runs pip
  with build isolation, which fetches setuptools from PyPI; bitbake gives
  `do_install` no network. The fix is inside upstream's pip invocation,
  which a bbappend cannot reach.

Project-side bbappends (`meta-edge-bsp/dynamic-layers/meta-deepx-m1/`,
parsed only when the layer is composed):

- `dx-driver_%.bbappend`: pins `SRCREV`, points `S` at the `modules`
  subtree (wrynose `UNPACKDIR` layout), builds with `CONFIG_RPI_BUILD=1` on
  `raspberrypi5` and fails the build if the resulting `dx_dma.ko` lacks the
  single-MSI string, drops the vendor's world-writable `99-dx-dma.rules`,
  and RDEPENDS on the exact `kernel-module-*-${KERNEL_VERSION}` packages
  (the vendor recipe names them without a versionless provider).
- `dx-rt_%.bbappend`: drops the SysV `dxrt-init` script; the daemon is a
  systemd unit here.

## Kernel facts the card depends on

All three were found on hardware and are now asserted at build time by
`do_edge_kernel_policy_assert` for the Pi kernel:

- `CONFIG_PCIE_BRCMSTB=y` — the bridge must exist before userspace.
- `CONFIG_BCM2712_MIP=y` — on BCM2712 the bridges take their MSI domain
  from the external MIP controllers (`msi-parent` in `bcm2712.dtsi`).
  With the MIP driver modular, fw_devlink held the built-in bridge in
  deferred probe until the 10 s timeout, after which it probed with no MSI
  domain and `dx_dma` failed `S-MSI allocation (-ENOTSUPP)`, as did RP1.
  Built in, the bridge probes at 0.5 s and `dx_dma` gets a `MIP-MSI` vector.
- `pcie_aspm=off` in the signed kernel command line (board include): with
  ASPM active the root port lets the endpoint enter a low-power link state
  from which its config space reads back as reset; the driver's link-health
  worker then takes a config-space read that BCM2712 escalates to a fatal
  SError on a ~10 s cadence. Global, so it also covers the RP1 link.

The single-MSI path (`RPi: forcing single MSI mode (brcmstb multi-MSI data
misalignment)`) comes from the vendor driver's `CONFIG_RPI_BUILD`; the
bbappend makes its presence in the built module a build-time check.

## Module signing

`dx_dma.ko` and `dxrt_driver.ko` are out-of-tree modules signed with the
same key as the in-tree ones; `edge_check_modules_signed` in the image
class rejects an unsigned module, and `MODULE_SIG_FORCE=y` would reject it
at load. With `LOCALVERSION_AUTO` off the kernel release is the plain
`6.18.52`, so the module directory and both modules' vermagic match the
pinned version rather than a git describe of the patched tree.

## Versions seen on the bench (2026-09-15)

| component | version |
|---|---|
| `dx-rt` | 3.4.1 (`DXRT v3.4.1+baec914`) |
| runtime driver (`dxrt_driver`) | v2.6.0 |
| PCIe driver (`dx_dma`) | v2.5.0 |
| card firmware | v2.7.4 (on the card; not delivered by this composition) |
| board | M.2, Rev 1.0, LPDDR5 5600 Mbps, 3.92 GiB |

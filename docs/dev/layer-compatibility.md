# Layer compatibility (`yocto-check-layer`)

`meta-edge-distro` and `meta-edge-bsp` are product layers. They exist to build
the `edge-ai` distribution for the boards this repo wires, and they are not
meant to be added to other builds. Neither claims Yocto Project Compatible
status. This page records which `yocto-check-layer` requirements the layers
meet, where they deliberately do not, and why.

## What the check tests

oe-core's `scripts/yocto-check-layer` adds a layer to a fresh build that uses
oe-core's default distro (`nodistro`), a QEMU machine and only the layer's
declared dependencies. The layer must then:

- carry a README (maintainer, patch instructions, an email address) and a
  `SECURITY.md`, set `LAYERSERIES_COMPAT`, and give every patch an
  `Upstream-Status`;
- parse, and pass `bitbake -e` and `bitbake -S none world`, without its distro
  or machines being selected;
- run no task other than `do_fetch` with network access;
- leave every other recipe's task signatures unchanged when the layer is added
  (the signature test). Adding the layer must not change a build that does not
  select its distro.

The layer type follows from its contents: `meta-edge-distro` has
`conf/distro/` and is checked as a distro layer. `meta-edge-bsp` has no
machine `.conf` of its own (the machines come from the vendor BSP layers;
`conf/machine/include/` holds only the per-board data), so it is checked as a
software layer and the BSP-specific tests do not apply.

## Met

| Requirement | How |
|---|---|
| README and `SECURITY.md` | `README.md` and `SECURITY.md` in each layer |
| `LAYERSERIES_COMPAT` | `conf/layer.conf` in each layer |
| `LAYERDEPENDS` lists every layer present in every composition that the layer appends or builds on | `conf/layer.conf`; vendor-specific content is under `dynamic-layers/` |
| `Upstream-Status` on every patch | also enforced by the build's `patch-status` QA |
| `meta-edge-distro` parses and builds `world` signatures under `nodistro`, with no network access outside `do_fetch` | — |
| defines its distro, does not set `DISTRO` | `meta-edge-distro/conf/distro/` |

## Deliberately not met

1. **`meta-edge-bsp` requires the `edge-ai` distro and an edge board.** Some
   classes and recipes check the distro's policy at parse time and stop the
   parse instead of skipping. Examples: `edge-image.bbclass` refuses a
   `MACHINE` without an `edge-board-<MACHINE>.inc`, and the RAUC configuration
   and bundle recipes require `EDGE_BOOT_CHAIN`. Under `nodistro` the layer
   therefore does not parse, and the check's `world`, signature and network
   tests do not reach it. Guarding these checks would only serve builds that
   do not exist; inside edge builds they turn a silent misconfiguration into
   an error.
2. **Appends modify upstream recipes for every distro.** The layers'
   `.bbappend` files (CVE backports, branding, security defaults) change their
   recipes without restricting the change to the `edge-ai` distro, so the
   signature test fails once a layer is added to another build. Scoping every
   append would touch almost all of them, and each change risks the images
   these layers exist to build, for no user of this project.
3. **Some Renesas-specific recipes live outside `dynamic-layers/`.** The DRP-AI
   runtime, application and runner recipes and the `packagegroup-edge-ai` and
   `packagegroup-edge-media` packagegroups depend on `meta-rz-bsp` and
   `meta-rz-distro` content. Those layers are composed only for the RZ/V2L, so
   they are not in `LAYERDEPENDS`. Images select these packagegroups per
   machine, and no edge build runs `world`.

Revisit these if a layer is ever offered for reuse outside this project.

## Running it

Run it inside the kas environment. The wrapper creates a throwaway build
directory, so `build/` is not touched, but the temporary build takes
`SSTATE_DIR` and `DL_DIR` from the shell environment when they are exported
there; set them to the caches this repo's builds use. Everything after `--`
goes to `yocto-check-layer`. Name the layer under test first, and list the
dependency layer directories one by one, since `.kas/` as a whole also
contains bitbake's test layers:

```bash
K=$PWD/.kas
export BOARD=rzv2l
. scripts/env.sh && kas shell kas/base.yml:kas/machines/rzv2l.yml:kas/local.yml -c \
  "yocto-check-layer-wrapper -- $PWD/meta-edge-distro --no-auto-dependency \
   --dependency $K/meta-openembedded/meta-oe $K/meta-openembedded/meta-python \
   $K/meta-selinux"
```

For `meta-edge-bsp`, add `--machines qemuarm64` and the remaining dependencies:
`meta-openembedded/meta-networking`, `meta-openembedded/meta-filesystems`,
`meta-rauc`, `meta-arm/meta-arm-toolchain`, `meta-arm/meta-arm`,
`meta-virtualization` and `$PWD/meta-edge-distro`.

`--no-auto-dependency` keeps the dependency layers out of the test: they are
only used, not tested.

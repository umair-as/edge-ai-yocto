# OP-TEE userspace — what ships, and how to select it

Design decisions and implementation reference for the normal-world OP-TEE
stack on the EDGE AI OS distro. Maps to CRA Annex I Part I §1 (minimum
attack surface) — see [CRA-CONTROLS.md](CRA-CONTROLS.md) for the
requirements view.

This covers the **normal-world** half only: the client library, the
supplicant, and the Trusted Applications installed into the image. The
secure-world half — OP-TEE OS as BL32 in the firmware chain — is not
optional and is not touched by anything here; see
[uboot-hardening.md](uboot-hardening.md) for the boot chain.

---

## Overview

`packagegroup-edge-optee` is the single entry point for OP-TEE userspace.
`edge-image.bbclass` installs it on `smarc-rzv2l` — the only machine in
this repo that wires BL32 — and every part of it is individually
selectable.

The packagegroup declares `COMPATIBLE_MACHINE` on itself, but BitBake does
not fail-soft on a `COMPATIBLE_MACHINE`-incompatible dependency: an image
on another machine listing it errors at parse with `Nothing provides
packagegroup-edge-optee`. Hence the machine-conditional append at the
image level, with the toggle applied inside it.

## Selection surface

Selection is not monolithic. Two variables, both declared in
`meta-edge-distro/conf/distro/include/edge-features.inc`:

| Variable | Default | Effect |
|---|---|---|
| `EDGE_ENABLE_OPTEE` | `1` | The whole normal-world stack. At `0` the packagegroup leaves the image entirely. |
| `EDGE_ENABLE_OPTEE_EXAMPLES` | `0` | Upstream demo TAs and their client applications (`optee-examples`). |

`optee-client` is the only unconditional member. It provides `libteec`,
`tee-supplicant`, and the `tee` group that owns `/dev/tee0` — without it
the secure world is unreachable from Linux, so it is not a choice.

Everything else is opt-in, which means an image ships a Trusted
Application only if something asked for it.

## Why the demo TAs are off by default

`optee-examples` is upstream's tutorial set (`hello_world`,
`secure_storage`, `random`, `aes`, …). Shipping it was the historical
default here; it is now opt-in, for three reasons:

1. **It is secure-world attack surface.** Each demo installs a loadable TA
   into `/lib/optee_armtz`. A TA runs in the secure world, above the
   kernel's privilege level — the one place in the system where the
   normal-world hardening in
   [`README.md`](../../README.md) does not reach.
2. **The demos are signed with the devkit's default key**, which is public
   and identical on every OP-TEE build in the world. That is correct for a
   tutorial and wrong for a fielded image.
3. **Every shipped package is a CVE-tracking obligation.** Packages that no
   workload calls still appear in the SBOM, still surface in the CVE
   report, and still cost triage time — see
   [cve-triage.md](cve-triage.md).

None of this makes the demos bad; they are the fastest way to prove a TEE
works end to end after a BL32 or devkit change. It makes them a
bring-up tool rather than image content, so the build asks for them
explicitly:

```bash
make dev OPTEE_EXAMPLES=1
```

For a bench that always wants them, set the toggle in the operator-private
`kas/local.yml` instead of passing the flag on every build:

```
EDGE_ENABLE_OPTEE_EXAMPLES = "1"
```

## Consequences of turning the stack off

`EDGE_ENABLE_OPTEE = "0"` is a wider change than dropping one
packagegroup, because two other things follow it:

| Follows the toggle | Where | Why |
|---|---|---|
| The xtest conformance slice (`packagegroup-edge-optee-test`) | `edge-image-dev.bb` | xtest against a TEE the image has no client stack for is dead weight. |
| `devel`'s membership of the `tee` group | `edge-users.inc` | The group is created by `optee-client`. `usermod` against a group that does not exist fails the rootfs task. |

The demos are not separately gated against it — with the packagegroup
gone, nothing installs them either way.

## Verifying a build

The resolved package set is the authoritative answer to "what is in this
image":

```bash
make shell   # then, inside:
bitbake-getvar -r packagegroup-edge-optee --value RDEPENDS:packagegroup-edge-optee
```

| Build | Resolves to |
|---|---|
| default | `optee-client` |
| `OPTEE_EXAMPLES=1` | `optee-client optee-examples` |
| `EDGE_ENABLE_OPTEE=0` | packagegroup absent from the image task graph |

## Verifying on-board

```sh
# Which TAs the image actually carries (UUID-named blobs)
ls /lib/optee_armtz/

# Supplicant running — required for secure storage and RPC
systemctl status tee-supplicant

# TEE reachable without sudo (devel is in the tee group)
id devel | grep -o 'tee'

# Demo TAs present only when the build opted in
command -v optee_example_hello_world
```

## Where the wiring lives

| File | Role |
|---|---|
| `meta-edge-distro/conf/distro/include/edge-features.inc` | Toggle declarations and defaults |
| `meta-edge-bsp/recipes-core/packagegroups/packagegroup-edge-optee.bb` | Member selection |
| `meta-edge-distro/classes/edge-image.bbclass` | Installs the packagegroup, machine- and toggle-gated |
| `meta-edge-bsp/recipes-core/images/edge-image-dev.bb` | xtest slice, dev tier only |
| `meta-edge-distro/conf/distro/include/edge-users.inc` | `tee` group membership for `devel` |
| `kas/optee-examples.yml` | Capability fragment behind `OPTEE_EXAMPLES=1` |

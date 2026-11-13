# ADR-0011: Kernel base is a per-board property, not a distro property

- Status: Accepted
- Date: 2026-09-09
- Amends: [ADR-0001](0001-kernel-base.md) (scope narrowed to RZ/V2L, where
  it remains accurate)

## Context

ADR-0001 states the kernel base as a platform-wide fact: "The kernel base
is **linux-cip 6.12**". That held while the platform had one board. It
does not survive a second one.

CIP SLTS is a property of a *source tree*, not of a distro. The Renesas
RZ/V2L path gets it because Renesas maintains `rz_linux-cip` on a CIP
branch. No equivalent exists for every board a platform might add: for
Raspberry Pi 5 the realistic providers are the vendor
`linux-raspberrypi` tree or a pinned kernel.org stable line, and neither
is CIP. A distro-scope assertion of "CIP 6.12" would therefore be either
false on the second board, or would force a board onto a kernel its
hardware enablement does not exist for.

The maintenance argument that motivated ADR-0001 also needs restating,
because the naive reading of it is wrong. ADR-0001's ~10-year horizon
comes from **CIP**, not from 6.12 itself. On kernel.org, 6.12 and 6.18
are both longterm releases with the *same* projected EOL (Dec 2028).
Putting a non-CIP board on 6.12 to match the version number therefore
buys **no additional maintenance horizon** — it only buys the appearance
of uniformity, while giving up whatever hardware enablement the newer
line carries.

## Decision

**1. The kernel base is chosen per board family, and recorded per board.**
In order of preference:

- CIP/SLTS where the vendor BSP provides it.
- A pinned kernel.org **longterm** line otherwise.
- The SoC vendor's tree, when it follows a kernel.org longterm line and the
  board's enablement exists in no longterm line. Its horizon is the lower of
  the longterm EOL and the vendor's maintenance of the branch.

| Board | Kernel | Pattern | Selected in | Horizon |
|---|---|---|---|---|
| rzv2l | `linux-renesas`, `rz-6.12-cip14` (ADR-0001) | CIP SLTS | `kas/bsp/renesas-rz-kernel.yml` | CIP SLTS |
| raspberrypi5 | `linux-edge-mainline`, kernel.org 6.18 | longterm, pinned | `kas/bsp/raspberrypi-kernel.yml` | Dec 2028 |
| ventuno-q | `linux-qcom` 6.18, Qualcomm `qcom-6.18.y` | vendor tree on a longterm line | `kas/bsp/qcom-kernel.yml` | Dec 2028, or earlier if Qualcomm stops the branch (no published end date) |

**2. Raspberry Pi 5 uses mainline-stable 6.18**, pinned by `SRCREV`,
carrying the board enablement patches its hardware needs.

**3. A board's kernel base is declared where its other board facts live** —
the machine's entry in the BSP layer — not in distro configuration. The
provider recipe name is BSP policy; a distro-scope
`PREFERRED_VERSION_<vendor-recipe>` applies a vendor-specific name to
every machine.

**4. The security posture is asserted, not assumed, on every provider.**
Providers differ in what they silently drop, so the platform's
load-bearing kernel symbols are checked against the *resolved* `.config`
and the build fails when one is missing. This is what makes a
multi-provider arrangement safe; it is not optional per board.

**5. Maintenance horizons are recorded per board and may differ** (table
above).

**6. VENTUNO Q uses Qualcomm's `linux-qcom` 6.18.** The board's device tree
(`monaco-arduino-monza.dts`) is absent from the 6.18 longterm line and from
mainline v7.0, and present from v7.1; at decision time (2026-10-19) the newest
longterm line is 6.18. `meta-qcom`'s `wrynose` default kernel carries it, on a
branch that follows the 6.18 stable releases: at the pinned revision, 2404
non-merge commits over v6.18.44. The `SRCREV` is `meta-qcom`'s, so the kernel
moves with the `meta-qcom` pin in `kas/bsp/qcom.yml`; fixes between pin bumps
are patches in this repo's `linux-qcom` bbappend. Mainline and stable 7.x
(including `meta-qcom`'s `linux-qcom-next`) are rejected as non-longterm;
6.18 longterm with the board carried locally is rejected because it means
carrying the vendor's SoC enablement as well. CVE matching sees only the stable
base version, so fixes or flaws in Qualcomm's own commits are per-CVE
dispositions.

## Rationale

Two providers is how multi-machine Yocto works; pretending otherwise
would mean either dropping a board or shipping a false claim.

6.18 for the Pi is chosen on evidence rather than symmetry. It is a
kernel.org longterm release with the same projected EOL as 6.12, so the
horizon is unchanged; it carries materially better BCM2712/RP1 support
than the 6.12 line; and the specific combination of that kernel with the
intended PCIe accelerator and with FIT-with-FDT signing is already
demonstrated on this exact board, which a 6.12-based Pi kernel is not.
Choosing 6.12 for the Pi would trade proven enablement for a version
number that confers no benefit.

Point 4 is the load-bearing half. Kernel config requests fail *quietly*:
a fragment naming a symbol the target kernel does not have produces no
output by default, and a requested symbol that never reaches `.config`
is a warning. Two of those failures were observed in practice on the
single-provider platform — an entire LSM was requested and silently not
built — which is what a second provider would multiply.

## Consequences

- ADR-0001's decision stands for RZ/V2L; its scope is narrowed from
  "the platform" to "this board".
- The platform tracks two kernel lines, with two CVE surfaces. Basic CVE
  identity hygiene applies to both; a full triage campaign on the second
  board is out of scope for its current demonstration role.
- Kernel policy shared by all boards must live in a provider-neutral
  include that each provider's bbappend requires, so a board cannot
  quietly miss part of it.
- Boards no longer share a kernel version, so any documentation stating
  one kernel version for the platform is wrong by construction.
- A future CIP SLTS series after 6.12 is the natural convergence point
  if both boards can move to it. None is announced.

## Revisit triggers

- CIP designates an SLTS series that both boards can adopt.
- A Raspberry Pi 5 kernel appears on a CIP branch.
- The chosen 6.18 pin approaches its Dec 2028 EOL, or the board's
  enablement lands in a longer-lived line.
- A board joins whose vendor BSP fits none of the three patterns. (The
  third pattern was added for the VENTUNO Q under this trigger.)
- For the VENTUNO Q: `meta-qcom` moves its default kernel off 6.18, the
  vendor branch stops following the 6.18 stable releases, or a longterm line
  carries the board.

# ADR-0011: Kernel base is a per-board property, not a distro property

## Status

Accepted. Amends the scope of [ADR-0001](0001-kernel-base.md), which
remains accurate for the board it describes.

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

- CIP/SLTS where the vendor BSP provides it. RZ/V2L keeps
  `linux-renesas` on `rz-6.12-cip14` (ADR-0001 unchanged).
- A pinned kernel.org **longterm** line otherwise.

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

**5. Maintenance horizons are recorded per board and may differ.**
RZ/V2L: CIP SLTS. Raspberry Pi 5: kernel.org longterm, Dec 2028.

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
- A third board joins whose vendor BSP fits neither pattern.

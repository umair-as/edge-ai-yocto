# ADR-0005: Image bbclass + OTA backend abstraction

- Status: Accepted
- Date: 2026-06-20

## Context

edge-ai-yocto, wrynose baseline. Approaching a second board addition,
the first DRP-AI vendor abstraction, and a future where the OTA backend
may not stay RAUC indefinitely. Image-policy plumbing today lives in a
`require`-based `.inc` file and an A/B WKS that names RAUC conventions
directly.

## Decision

Three structural moves, taken together:

1. **Promote image policy from `.inc` to `.bbclass`.**
   `meta-edge-bsp/recipes-core/images/edge-image-common.inc` becomes
   `meta-edge-distro/classes/edge-image.bbclass`. Image recipes
   `inherit` it instead of `require`-ing the include. Same content,
   semantically correct relationship.

2. **Carve A/B-slot semantics into a separate class.**
   `edge-ab-image.bbclass` inherits `edge-image` and adds the
   two-rootfs contract: `EDGE_SLOT_A_LABEL` / `EDGE_SLOT_B_LABEL`
   variables, shared `/boot` semantics, `/data` layout, slot-by-label
   udev policy. The split keeps `edge-image.bbclass` usable for a
   future single-rootfs variant (development-host image, qemu CI
   image) without dragging A/B assumptions in.

3. **Push every OTA-backend-specific decision behind virtual
   providers selected by `EDGE_OTA_BACKEND`.**
   The image classes **never** name the backend. `edge-ota-rauc.inc`
   binds `virtual-ota-uboot-env` and `virtual-ota-confirm-boot` to
   RAUC-specific recipes and sets the slot labels. Switching to
   mender or swupdate is `EDGE_OTA_BACKEND = "mender"` in
   `local.yml`, a new `edge-ota-mender.inc`, and new recipes that
   provide the same virtual contracts. No image class change.

The mapping from today's RAUC-named surface to the abstraction:

| Concern                | Today                          | Abstraction                              |
| ---                    | ---                            | ---                                      |
| Slot labels            | `rootfsA`, `rootfsB`           | `EDGE_SLOT_A_LABEL`, `EDGE_SLOT_B_LABEL` |
| Bootloader env mgmt    | `rauc-uboot-env-init.service`  | `virtual-ota-uboot-env` provider         |
| Boot health-mark       | `rauc status mark-good`        | `virtual-ota-confirm-boot` provider      |
| Boot cmdline frag      | `rauc.slot=${rauc_slot}`       | Backend appends to `EXTRA_KERNEL_ARGS`   |
| Runtime tooling        | `rauc`, `edge-grow-data`       | `IMAGE_INSTALL` from backend include     |
| Slot-state machine     | `BOOT_ORDER` / `BOOT_x_LEFT`   | Encapsulated in the backend's env init   |

A parse-time `__anonymous` gate in `edge-ab-image.bbclass` raises
`bb.parse.SkipRecipe` if `EDGE_OTA_BACKEND` is unset — failing clean
at parse beats failing weirdly at do_rootfs when the backend
include is forgotten.

## Rationale

Three pressures converging:

- **Multi-board.** Cross-cutting image policy (FSTYPES, IMAGE_FEATURES
  floor, the WIC fstab-update workaround, `selinux-image` inherit,
  postprocess hooks) lives once. A second board is a new WKS + machine
  yml, not a re-derivation of policy.

- **Multi-card-size.** WKS becomes a `.wks.in` template parametrised
  on `EDGE_SLOT_SIZE_MB` and `EDGE_DATA_SIZE_MB` (enrolled in
  `WICVARS`). A 128 GB card variant is a machine override, not a new
  WKS copy. Eliminates the n-files-for-n-sizes maintenance pattern.

- **OTA portability.** The cost of abstracting the OTA backend before
  it grows DRP-AI scaffolding on top is much lower than retrofitting
  after. The virtual-provider boundary is small today (two providers,
  three image-class variables) and grows only if uncontained.

The WIC update-fstab trap that motivated this ADR is a useful concrete
example: a build-system bug whose fix is one variable
(`WIC_CREATE_EXTRA_ARGS:append = " --no-fstab-update"`) but which
naturally belongs at the image-class level, not per-recipe and not in
the WKS. The same shape applies to every future cross-cutting policy.

## Consequences

**Positive.**

- Second board addition is a leaf change (new `.wks.in`, new machine
  yml), not a re-derivation of image policy.
- A second OTA backend, when needed, is two new files
  (`edge-ota-X.inc` plus a virtual-provider recipe), parse-tested
  before any build runs.
- `bitbake-layers show-recipes 'edge-image-*'` continues to enumerate
  the same image tiers; only the inheritance chain changes.
- Forgetting `EDGE_OTA_BACKEND` is a parse error, not a do_rootfs
  surprise. Operator-facing failure mode is named and crisp.
- The DRP-AI / model-store partition decision (deferred to a future
  ADR) becomes an additive change at the class level — one
  partition added to the `.wks.in` template plus an
  `EDGE_MODELS_SIZE_MB` variable.

**Negative.**

- One-time mechanical refactor (~2-3 hours): rename, edit per-tier
  `inherit` lines, move RAUC-named files behind virtual providers,
  parameterise the WKS. Verification needs one full image build.
- Indirection cost: a reader chasing the slot label has to follow
  `edge-ab-image.bbclass` → `edge-ota-rauc.inc` → `EDGE_SLOT_A_LABEL`.
  Tolerable; documented in the bbclass header.
- The `virtual-ota-uboot-env` provider name is a coin-flip naming
  choice; if mender's binding diverges enough that one provider
  doesn't fit both, the abstraction layer pays for the misnomer.

## Scope and non-scope

**In scope.**

- Image-class layering, OTA-backend virtual-provider boundary, WKS
  template parametrisation, slot-label abstraction, parse-time
  backend-required gate.

**Out of scope.**

- Bundle / artifact recipe portability. RAUC bundle and Mender
  artifact are different shapes; each backend ships its own bundle
  recipe. The image class does not abstract this.
- Multi-board WKS deduplication. Boards genuinely differ in
  bootloader offsets and partition map; one `.wks.in` per board is
  correct. [ADR-0006](0006-emmc-gpt-boot-target.md) adds a per-boot-target
  WKS dimension (eSD/MBR vs eMMC/GPT for the same board), selected by
  `EDGE_BOOT_TARGET`.
- Three-slot (A/B + recovery) image layouts. Hardcode A/B for v0;
  add an `edge-ab-recovery-image.bbclass` that inherits
  `edge-ab-image` if a real recovery-slot use case ever materialises.
- DRP-AI / model-store partition wiring. Deferred until the model
  artifact format is settled (a separate ADR will cover that
  decision).

## Implementation status

Phases 1-4 of the staged plan landed as metadata reshape; Phase 5
deferred. Current state:

- **Phase 1 (rename .inc → .bbclass)** — `edge-image-common.inc`
  removed; `meta-edge-distro/classes/edge-image.bbclass` is the
  inherit target.
- **Phase 2 (A/B carve-out)** — `edge-ab-image.bbclass` holds the
  A/B contract and parse-time gate for `EDGE_OTA_BACKEND`.
- **Phase 3 (WKS template)** — `edge-image-rzv2l.wks` →
  `edge-rzv2l.wks.in`; slot labels and sizes are bitbake-time
  variables (`EDGE_SLOT_A_LABEL` etc.).
- **Phase 4 (OTA provider boundary)** —
  `u-boot-env-config_1.0.bb` renamed to `rauc-uboot-env_1.0.bb`;
  `RPROVIDES:${PN} = "virtual-ota-uboot-env"`. `edge-ota-rauc.inc`
  binds the virtual via `PREFERRED_RPROVIDER_virtual-ota-uboot-env`
  and owns the RAUC slot labels. `packagegroup-edge-base` RDEPENDS
  on the virtual, never on the PN. Verified: parse-time correctness,
  on-target boot, and `bitbake -e edge-image-base | grep
  EDGE_SLOT_A_LABEL` shows the RAUC-bound value (`rootfsA`).
- **virtual-ota-confirm-boot** — deferred. No `mark-good` / boot-
  confirm service exists in the codebase; introducing a placeholder
  recipe for nonexistent functionality is premature. Revisit when
  application-level boot-health gating becomes a real requirement.
- **Phase 5 (mender stub)** — deferred until mender is a real
  requirement. `EDGE_OTA_BACKEND=mender` currently fails with
  `Could not include required file ... edge-ota-mender.inc`,
  which is the intended failure mode.

## Revisit triggers

- A second OTA backend is actually selected for a customer / contract
  build. The `virtual/ota-*` boundary either holds or reveals
  pressure points; either way it deserves a follow-up ADR documenting
  the second binding's specifics.
- A board with a genuinely different slot model (A/B + recovery,
  failsafe boot ROM, NOR + eMMC tiered). Likely triggers an
  `edge-ab-recovery-image.bbclass` or similar.
- DRP-AI / NPU-vendor model store decision lands. Either folds into
  the WKS template parameter set or creates a new partition class —
  separate ADR.
- WIC ever fixes its `update_fstab()` to dedup before write. The
  `WIC_CREATE_EXTRA_ARGS:append = " --no-fstab-update"` line in
  `edge-image.bbclass` becomes redundant; harmless to keep, but
  worth noting in the header comment.

## References

- [RAUC documentation](https://rauc.readthedocs.io/) — A/B update framework, bundle formats, slot configuration.

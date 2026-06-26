# ADR-0004: Persistent state via selective bind mounts (not overlayfs)

- Status: Accepted
- Date: 2026-06-17

## Context

RAUC A/B updates replace the inactive rootfs slot wholesale; the shared
`/data` partition is never touched by an install. Any state that must
outlive an update — journals, the container image store, SSH host keys,
the systemd machine-id, operator `/home` — has to live on `/data`. The
question is *how* the running OS exposes `/data` to the rest of the system.

Two architectures were considered: a **blanket overlayfs** (capture all
writes to `/etc`, `/var`, `/home` onto `/data`) versus **selective bind
mounts** (an explicit, enumerated list of persistent paths). The choice
must compose with goals already on the roadmap: kernel-enforced integrity
(IMA/EVM today, verity-`/usr` later), a read-only rootfs, SELinux MAC, and
stable per-slot identity (host-key fingerprint and machine-id must survive
an update).

## Decision

Persist state by **bind-mounting individually enumerated directories** from
`/data` subdirs over the matching rootfs paths. Each bind is one systemd
`.mount` unit, declared in the recipe layer and gated by `data.mount`. No
overlay filesystem captures writes.

Single-file identity material (`/etc/machine-id`,
`/etc/ssh/ssh_host_*_key{,.pub}`) is persisted by **oneshot
capture-or-restore services** that run before the consuming daemon opens
the file — not bind-mounted.

`/data` is seeded from rootfs content on first boot by a oneshot that runs
after `data.mount` but before the binds activate; it populates empty
`/data` subdirs without overwriting operator state, idempotent via a
`/data/.edge-seeded` marker.

The v0 bind set:

```
/data/log/           ↔  /var/log               (journals, audit, lastlog)
/data/containers/    ↔  /var/lib/containers    (podman image store)
/data/systemd/       ↔  /var/lib/systemd       (random-seed, timers, state)
/data/home/          ↔  /home                  (user data)
/data/crash/pstore/  ↔  /var/lib/systemd/pstore (kernel crash archives)
```

Identity services: `edge-machine-id-persist.service` (before
`systemd-machine-id-commit`) and `edge-ssh-host-keys-persist.service`
(before `sshdgenkeys.service`).

## Rationale

Overlayfs-on-`/etc`+`/var` is the "obvious" alternative; it is rejected:

- **IMA/EVM does not support overlayfs** — EVM emits `evm: overlay not
  supported` on the first xattr op through an overlay mount. EVM is a hard
  requirement for the audit posture.
- **SELinux labeling is hostile over overlay** — synthesized
  `security.selinux` xattrs merge stale upper-layer labels with a fresh
  lower-layer ext4 on every slot swap. Bind mounts preserve the underlying
  inode's label; one relabel pass on `/data` settles it.
- **Slot-transition reconciliation is unbounded** — an overlay upper layer
  accumulates the old slot's `/etc` edits on top of a *different* new-image
  `/etc`; reconciling additions, removals, and stale content needs a
  several-hundred-line three-way-merge program maintained forever. Bind
  mounts persist only what the recipe names; everything else comes from the
  booted slot's rootfs — nothing to merge.
- **Implicit capture grabs too much** — a blanket `/var` overlay also
  persists coredumps, per-package transient state, and package-DB state,
  with no way to tell what survives a swap without inspecting a live upper
  layer. With binds, the answer is the recipe file.
- **Verity-friendly** — a bind architecture is invariant to a read-only /
  dm-verity rootfs and composes with systemd-sysext; overlay-on-`/etc`
  does not.
- **Enumerable from source** — `grep -rl data.mount meta-edge-*` lists
  every persistent path. For an IEC 62443 / CRA posture, enumerating
  persistent state from source is itself a deliverable.

The pattern is the established "impermanence" shape (NixOS impermanence,
ChromeOS stateful binds, rpm-ostree) — a build-determined rootfs plus an
explicit persistent bind set — not a novel design.

## Consequences

**Positive.**

- Persistent surface is fixed at build time and enumerable from the recipe
  layer; "what survives a slot swap?" is answered from source.
- Each bind is an independent unit — a failed `/var/lib/containers` mount
  does not cascade into `/var/log` or `/home`.
- Composes with the roadmap (IMA/EVM, SELinux relabel, dm-verity, sysext)
  without architecture change.
- The container image cache is shared across slots, so vendor layers are
  not re-pulled after an update (layers carry signed manifests, verified at
  launch).

**Negative / accepted trade-offs.**

- **Operator `/etc` edits do not survive a slot swap by default** —
  configuration is a build input plus operator drop-ins under a designated
  persistent path, not arbitrary `/etc` capture. Per-device config that
  must follow the device goes under `/data` with the consumer pointed at
  it; no consumer needs this today (systemd-networkd config is image-baked,
  leases in `/run`).
- **Adding a persistent path is a recipe change + build + bundle** —
  intended; the platform refuses to silently expand the persistent set.
- **More recipe files** than one overlay script (five `.mount` units, a
  tmpfiles entry, seed + two identity services) — declarative INI/shell
  with named edges; readability is judged worth it.
- **Small per-package state is not persisted** (`/var/lib/dbus`,
  `/var/lib/alsa`, …) — recreated on first use; cost is kilobytes, benefit
  is no schema-skew surprises across slots.

**Boundaries.** The platform does not capture the kernel cmdline / U-Boot
env / boot-counter (the bootloader owns those), does not bind `/etc` itself
(slot-local `/etc` keeps drift off the rollback target), does not persist
`/var/lib/rauc` (RAUC uses `/data/rauc/` via `data-directory=`), and does
not persist `/tmp` or `/var/tmp` (tmpfs on `/var/volatile`; volatile-binds
are disabled only for `/var/log` and `/var/tmp` so the bind target and
`PrivateTmp=` sandboxes resolve).

## Revisit triggers

- A fleet requirement to "stamp a `/etc` change once and have it follow the
  device." The smallest additive answer is a `/data/edge/conf.d/` drop-in
  read via a systemd include, or an explicit `/etc/edge.d/` bind — revisit
  the whole architecture only if the fleet wants *implicit* `/etc` capture
  (a posture reversal, not a tooling change).
- A move to a unified verity-extension layer where `/usr` and `/etc` both
  become slot-local; at that point revisit whether `/etc` splits into a
  verity-sealed base plus a small persistent surface.

## Note: bind-target preparation order

A bring-up trap worth recording. Using `systemd-tmpfiles.d` to create the
`/data/*` subdirs and ordering the seed `After=systemd-tmpfiles-setup.service`
produces a dependency cycle (`local-fs.target → var-log.mount →
systemd-tmpfiles-setup → local-fs.target`). Systemd breaks it by dropping a
job, so tmpfiles-setup runs *before* `/data` is mounted, its `/data/*`
entries land in the rootfs and are shadowed by the partition mount, and
downstream services fail on missing subdirs.

The fix: the seed and identity-persist services **`mkdir -p` their own
target subdirs** rather than depending on tmpfiles ordering; the
`tmpfiles.d` file still applies perms later over already-existing dirs.
Generalises: any oneshot running before `local-fs.target` should create its
own state dirs.

## References

The "impermanence" pattern (build-determined rootfs + an enumerated
persistent bind set) as shipped by:

- [NixOS impermanence](https://github.com/nix-community/impermanence) — enumerated persistent-path binds over an ephemeral root.
- [rpm-ostree](https://coreos.github.io/rpm-ostree/) — immutable `/usr`, file-level `/etc` merge, `/var` on its own partition.
- [ChromeOS verified boot](https://www.chromium.org/chromium-os/chromiumos-design-docs/verified-boot/) — per-domain stateful-partition binds over a verified rootfs.

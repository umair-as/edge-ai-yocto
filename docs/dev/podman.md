# Podman on edge-ai-yocto — operator + dev guide

> **Validated on bench 2026-06-19** against `edge-image-dev` on a SMARC
> RZ/V2L EVK booted to RAUC slot A, SELinux Permissive, kernel
> 6.12.43-cip7-yocto-standard. Stack captured: podman 5.8.3-dev,
> crun 1.26, netavark 1.17.2, aardvark-dns 1.17.0, pasta available.
> `scripts/dev/edge-smoke-test.sh` returned 44 PASS / 0 FAIL.

Container userspace on edge-ai-yocto runs **rootless by default**, with
the rootful path reserved for boot-time managed services. This document
covers the daily-use commands as `devel`, the rootless mapping model,
networking, storage survival across OTA, and the gotchas worth knowing.

## TL;DR

Three things the stack earns us, given the SELinux/podman work this
session:

1. **One-command rootless workflow.** `ssh devel@<board>` → `podman
   pull` → `podman run`. No `sudo`, no Docker daemon, no nudges from
   the operator perspective.
2. **OTA-survives container state.** `$HOME/.local/share/containers`
   lives on `/home`, which is bind-mounted from `/data/home`. RAUC
   swaps the rootfs slot; the container store and image cache stay.
3. **Production-shape networking.** netavark + aardvark-dns means each
   user-defined network has its own DNS server, containers resolve
   each other by name, and the same setup ships on rootful and
   rootless.

## Stack components

After the next image rebuild lands (passt + e2fsprogs-tune2fs + SELinux
labels + WIC fstab fix), the on-board stack is:

| Component        | Role                                     | Package                   |
| ---              | ---                                      | ---                       |
| `podman`         | CLI + image / container / network engine | `podman`                  |
| `conmon`         | per-container monitor + log routing      | `conmon`                  |
| `crun`           | OCI runtime (lightweight, C, fast start) | `crun`                    |
| `netavark`       | networking backend (since podman 4.x)    | `netavark`                |
| `aardvark-dns`   | DNS server bound per user-defined net    | `aardvark-dns`            |
| `pasta`          | rootless network namespace plumbing      | `passt` (provides pasta)  |
| `slirp4netns`    | older rootless netns fallback            | `slirp4netns`             |
| `skopeo`         | image-only ops (copy, inspect, sign)     | `skopeo`                  |
| `catatonit`      | tiny PID-1 init for containers           | `catatonit`               |

The set ships via `packagegroup-edge-containers`, toggled at the distro
level by `EDGE_ENABLE_CONTAINERS=1` (already on for dev images that
include `packagegroup-edge-dev`).

## Two posture modes

| Mode      | Who runs it       | Networking                           | Storage root                                  | When to use                                  |
| ---       | ---               | ---                                  | ---                                            | ---                                          |
| Rootless  | `devel` (uid 1000)| pasta (default) / slirp4netns / host  | `~/.local/share/containers`                    | All interactive / dev / app workloads        |
| Rootful   | `root`            | netavark bridge / host                | `/var/lib/containers`                          | Boot-time services that need privileged caps |

**Lean rootless first.** Rootful exists for the case where a
container needs CAP_NET_ADMIN-from-host or has to bind ports < 1024
without `net.ipv4.ip_unprivileged_port_start` tuning. Everything
operator-facing should be rootless.

## Rootless mapping — the mental model

```
host UIDs                              container UIDs
─────────                              ──────────────

uid 0      (root, runs system)
...
uid 1000   (devel, runs podman)  ───►  uid 0   (root inside container)
...
uid 100000 (subuid base, devel)  ───►  uid 1
uid 100001                       ───►  uid 2
...
uid 165535 (devel subuid end)    ───►  uid 65535

GIDs map identically via /etc/subgid.
```

The mapping is read from `/etc/subuid` + `/etc/subgid`. Both files get
the `devel:100000:65536` entry written by `useradd`'s postinst at
image-build time — **we do not ship these files**, because doing so
fixes the mapping per-host even when other tooling (e.g. an admin
adding a second user) would otherwise extend it.

`newuidmap` / `newgidmap` live at `/usr/sbin/newuidmap` and
`/usr/sbin/newgidmap`, setuid root. Without setuid, rootless silently
falls back to `vfs` storage, kills inter-container networking, and
generally tanks. If you ever see `Store.GraphDriverName: vfs` in
`podman info --format '{{.Store.GraphDriverName}}'`, check
`ls -l $(which newuidmap)` first.

## First-time setup on a fresh flash

`su - devel` is **not** sufficient — it doesn't go through PAM, so
`pam_systemd` never creates a logind session, no `XDG_RUNTIME_DIR`,
no `user@1000.service`. Rootless podman then falls back to cgroupfs
and `/tmp/storage-run-1000`, with a flood of cgroupv2 warnings.

Either log in fresh as `devel` (SSH or console) **or** as root enable
linger and reconnect:

```
# from root (one-shot per board, persists across reboots and OTAs):
loginctl enable-linger devel
```

Confirm the session is live:

```
ssh devel@<board>
echo "$XDG_RUNTIME_DIR"                      # /run/user/1000
loginctl show-user devel | grep -E 'Linger|State'
# Linger=yes
# State=active
systemctl --user is-active default.target    # active
```

## Daily iteration loop

```
podman pull docker.io/library/alpine:3.20
podman run --rm alpine:3.20 echo "container says hi"

# detached service, port published on the host:
podman run -d --name nginx -p 8080:80 docker.io/library/nginx:alpine

# inspect + tail logs:
podman ps
podman logs -f nginx

# build a local image (uses buildah under the hood):
podman build -t edge/myapp:dev /path/to/Dockerfile-dir

# graceful teardown:
podman stop nginx
podman rm nginx
podman image prune
```

`podman ps` and `podman images` are scoped per user. `devel`'s
containers are invisible from `root`'s podman, and vice versa.
Same goes for the image store.

## Networking modes

Pick by what the workload needs, not by what's convenient:

| Mode               | Selected by                               | When to use                                          | Caveats                                         |
| ---                | ---                                       | ---                                                  | ---                                             |
| Default (`bridge`) | `podman run --network bridge` (or omit)   | Multi-container apps with inter-container DNS        | Requires pasta on rootless (5.x default)        |
| `host`             | `podman run --network host`               | App must share the host's net namespace              | Container sees host's interfaces; no isolation  |
| `none`             | `podman run --network none`               | Fully offline workloads                              | No interfaces at all                            |
| User-defined       | `podman network create my-net`, then `--network my-net` | App needs an isolated subnet + per-net DNS | netavark + aardvark-dns; pasta-backed on rootless |
| `slirp4netns`      | `podman run --network slirp4netns`        | Fallback on images that ship slirp4netns but not pasta | Per-container netns; lacks aardvark-dns binding |

On the next image (with `pasta` installed), the default rootless mode
is pasta. On the current bench image (no pasta), `--network slirp4netns`
is the operator workaround until reflash.

## Inter-container DNS via aardvark-dns

Two containers on the same user-defined network resolve each other by
container name. aardvark-dns binds 127.0.0.x:53 inside the namespace
and answers from a static map netavark publishes per-network.

```
# create the bridge
podman network create demo-net

# server, named so DNS picks it up
podman run -d --name api --network demo-net \
  docker.io/library/nginx:alpine

# client, resolves "api" → 10.x.x.x via aardvark
podman run --rm --network demo-net alpine:3.20 \
  sh -c 'wget -qO- http://api/'

# cleanup
podman stop api && podman rm api && podman network rm demo-net
```

If `nslookup api` from inside a container returns NXDOMAIN, check
`podman network inspect demo-net` for the `dns_enabled: true` flag.
Disabled DNS means the network was created against an older
netavark — easiest fix is `podman network rm` and recreate.

## Storage layout — OTA survival

```
/var/lib/containers          ← rootful store (mounted from /data/containers)
~/.local/share/containers    ← rootless store, per-user
~/.config/containers         ← rootless config (storage.conf, etc.)
```

Persistence chain via `edge-persistence`:

```
/data partition
├── containers/          ──bind──►  /var/lib/containers
├── home/                ──bind──►  /home
│   └── devel/.local/share/containers   (rootless store rides on /home)
└── ...
```

`rauc install` swaps the rootfs slot; `/data` stays put. Image cache,
container state, volumes, and user config all survive. The trade-off:
a corrupt image cache survives OTA too. `podman system prune` is your
friend on the rare day you need to reset.

## Subid mapping — why it's a postinst, not a shipped file

`/etc/subuid` and `/etc/subgid` get the `devel:100000:65536` entry
written by `useradd` during the **postinst step at image build time** —
no `file://subuid` recipe ships these files. Two reasons:

1. **Idempotency under user additions.** If `/etc/subuid` shipped as
   a static file, adding a second user later (via `useradd` at runtime)
   would expand the file. A re-flash would clobber that expansion.
   Postinst-only means each install is consistent with the current
   `passwd` state.
2. **Per-host distinct ranges.** `useradd --add-subuids` picks the
   next available range. Shipping a fixed mapping makes the range
   identical across every flashed board; pre-shipping leaks
   image-level state into a runtime-managed file.

The trade-off: there's no single source of truth in the recipe layer
for "what subuid range does devel have." If you need it,
`grep ^devel: /etc/subuid` on any booted board.

## Hardware passthrough

Limited but real, all gated by the host's `--device` and group memberships:

| Need                            | How                                                            |
| ---                             | ---                                                            |
| GPIO / I²C / SPI device         | `--device /dev/i2c-1 --device /dev/spidev0.0`                  |
| /dev/dri (DRM render)           | `--device /dev/dri --group-add render` (devel is in `render`)  |
| USB devices                     | `--device /dev/bus/usb/...` or `--device /dev/ttyUSB0`         |
| Camera (V4L2)                   | `--device /dev/video0 --device /dev/media0 --group-add video`  |
| /sys/class/* read access        | Default (rootless can read /sys, can't write most)             |
| /dev/mem, /dev/kmem             | Rootful only; rootless is denied by capability                 |

The `devel` user is in `video`, `audio`, `render`, `input`, `dialout`,
and `wayland` groups by default (per `meta-edge-distro/recipes-core/users/`).
That covers most of the bring-up surface without `sudo`.

## Known gotchas

- **`su - devel` ≠ logind session.** Use `ssh devel@<board>` or
  `loginctl enable-linger devel` from root. Symptom: cgroupfs warnings
  on every podman call, `XDG_RUNTIME_DIR` unset.
- **Pasta is the default rootless netns.** Shipped via `passt`
  (`/usr/bin/pasta`); `podman info` reports it as the rootless network.
  Older fallback if ever needed: `podman run --network slirp4netns ...`.
- **`user.max_user_namespaces`.** Rootless containers depend on this
  kernel sysctl. The image ships it at 28633 via
  `meta-edge-bsp/recipes-support/edge-sysctl-hardening/`. If you see
  `Operation not permitted` on `podman unshare`, check
  `sysctl user.max_user_namespaces`.
- **SELinux interactions.** The image boots **permissive** with the
  **MCS** policy (`SELINUXTYPE=mcs`, `Policy MLS status: enabled`).
  Container labels come from the `container_t` domain; AVC denials log
  to audit but don't block. Flip to enforcing only after a clean
  `ausearch -m AVC` over a real workload. MCS is **mandatory** for
  rootless networking: netavark relabels its netns/overlay dirs with
  4-field `:s0` contexts, and a non-MCS policy (`refpolicy-standard`)
  rejects those at `lsetxattr()` with `EINVAL` — a context-*validity*
  failure that permissive does not soften and `--security-opt
  label=disable` does not bypass.
- **netavark uses the nftables firewall driver.** Set via
  `firewall_driver = "nftables"` in containers.conf (`10-edge-network.conf`).
  The kernel ships a complete `nf_tables` set but not the full xtables
  match set (no `xt_comment`), so netavark's *default* iptables driver
  aborts bridge rule setup with `Extension comment ... missing kernel
  module` / `iptables: No chain/target/match by that name`. If bridge
  networking breaks, confirm the driver is still nftables.
- **Container IPs change between netavark restarts.** Don't hardcode
  IPs in app config; use container names + aardvark-dns.

## Verifying after an OTA

```
ssh devel@<board>
podman info --format '
backend: {{.Host.NetworkBackend}}
netpkg:  {{.Host.NetworkBackendInfo.Package}}
dnspkg:  {{.Host.NetworkBackendInfo.DNS.Package}}
storage: {{.Store.GraphDriverName}}
rootless:{{.Host.Security.Rootless}}'
which pasta && pasta --version
podman ps -a       # surviving containers from before OTA
podman images       # surviving image cache from before OTA
```

If `storage` reads `vfs`, network reads `cni`, or pasta is missing,
the runtime drifted — file an issue with the output.

## References

- `docs/dev/quadlet.md` — systemd-native container deployment via
  `.container` files; the right way to ship long-lived services
- `meta-edge-bsp/recipes-core/packagegroups/packagegroup-edge-containers.bb`
  — the package set
- `meta-edge-bsp/recipes-core/edge-containers-config/` — runtime overrides
  for `storage.conf`, `containers.conf`, and the `edge-network` bridge
- `meta-edge-distro/conf/distro/include/edge-features.inc` —
  `EDGE_ENABLE_CONTAINERS` toggle
- `meta-edge-bsp/recipes-core/edge-persistence/` — bind-mount layer
  that gives containers their OTA-surviving store
- ADR-0004 (persistent state architecture) — why `/data` is the
  bind-mount target

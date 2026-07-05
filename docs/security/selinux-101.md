# SELinux on edge-ai — a 101 plus the local wiring

This is the working-knowledge primer for anyone who maintains, debugs, or
flips the SELinux posture on this distro. It assumes you've used Linux but
not SELinux. The first half explains the concepts; the second half maps
them to the exact files in this tree.

## 1. Why LSM exists

The traditional UNIX permission system is **discretionary access control**
(DAC). The file owner decides who can read/write/execute. uid 0 (root)
bypasses all checks. This is enough for a single-user workstation but
leaves no room for a security policy that the operator gets to enforce
*above* the application — and offers no answer to the "confused deputy"
problem (a privileged process being tricked into using its privilege
against the user).

**LSM** (Linux Security Module) is the kernel framework that adds a second
layer: **mandatory access control** (MAC). Before any access check
completes, the kernel calls into a stack of LSM hooks. Each hook can DENY
the access regardless of what DAC said. So even root can be restricted:
"this process is in security domain X — it may only open files labelled Y."

```
   userspace:  open("/etc/passwd", O_RDONLY)
                          |
                          v
                  +----------------+
                  | syscall layer  |
                  +----------------+
                          |
                          v
                  +----------------+
                  | DAC checks     |     classic UNIX layer
                  | uid / gid /    |     ── owner decides
                  | mode bits      |
                  +----------------+
                          |
                  (DAC says ok)
                          |
                          v
                  +----------------+
                  | LSM hooks      |     MAC layer
                  |  Lockdown      |     ── operator's policy
                  |  Yama          |        wins over root
                  |  BPF           |
                  |  Landlock      |
                  |  **SELinux**   |     ── this is where the
                  +----------------+        access actually
                          |                 gets allowed/denied
                 (any LSM may deny;
                  SELinux usually does
                  the deciding for us)
                          |
                          v
                   file descriptor
```

LSM is a stack. Multiple LSMs run side-by-side:

| LSM | What it does | In our build? |
|---|---|---|
| Lockdown | Reduces kernel attack surface (no /dev/mem, no kexec, no module loading without integrity, etc.) | yes |
| Yama | Restricts ptrace to parent-child relationships | yes |
| BPF | Constrains eBPF program loading | yes |
| Landlock | Sandboxing API that unprivileged processes can use on themselves | yes |
| AppArmor | Path-based MAC (one profile per binary) | **no** — we don't ship profiles |
| **SELinux** | **Type-enforcement MAC (labels everywhere)** | **yes — the active MAC** |
| SMACK / TOMOYO | Alternative MACs | no |

Only **one** of {SELinux, AppArmor, SMACK, TOMOYO} can be the active MAC
at a time — they're "exclusive" LSMs. The non-exclusive ones
(Lockdown, Yama, BPF, Landlock) stack alongside.

The `CONFIG_LSM=` kernel string defines initialization ORDER. We set:

```
CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"
```

SELinux is last so its hooks see context already resolved by the others.

## 2. SELinux concepts

### 2.1 Everything has a label

Every process and every kernel object (file, socket, sysfs entry, IPC
endpoint, …) carries an SELinux label. A label has four fields:

```
   system_u   :   object_r   :   ssh_home_t   :   s0
   ^^^^^^^^       ^^^^^^^^       ^^^^^^^^^^       ^^
      |              |                |            |
     user           role             TYPE        level
   (RBAC)        (RBAC)         (TE — the part   (MCS/MLS,
   advanced     advanced         policy actually  almost
                                    decides on)   always s0
                                                  for us)
```

For most policy decisions only the **type** matters. The others are for
advanced setups (multi-category / multi-level security).

### 2.2 Type Enforcement (TE) — the core model

- **Subject** (a running process) has a **domain**, which is a type like
  `sshd_t`, `httpd_t`, `init_t`.
- **Object** (a file, socket, ...) has a type like `etc_t`, `var_log_t`,
  `tmp_t`.
- The policy is a long list of `allow` rules: `allow DOMAIN
  OBJECT_TYPE:OBJECT_CLASS PERMISSION`.

```
   subject                                       object
   +----------+                            +------------------+
   | process: |     wants to:              | /var/log/secure  |
   | sshd     | --- "open this file" --->  | (regular file)   |
   | domain   |                            | type = var_log_t |
   | = sshd_t |                            | class = file     |
   +----------+                            +------------------+
                          |
                          v
              +------------------------------+
              | Policy lookup:               |
              |   allow sshd_t               |
              |         var_log_t:file       |
              |         { open read append } |
              +------------------------------+
                          |
                  found a matching rule?
                          |
            yes ──────────┴────────── no
             |                         |
             v                         v
          GRANTED                    DENIED
                                     (logged to audit
                                      in any mode;
                                      blocked only
                                      when enforcing)
```

If no rule says `allow sshd_t var_log_t:file open`, sshd can't open files
of type `var_log_t`. Default-deny. Done.

There are no "groups" or "users" in policy — only types and the
type-transition rules that move processes between domains as they exec
new binaries.

### 2.3 Where labels come from

| Object | Label source |
|---|---|
| Files on disk | extended attribute `security.selinux` (xattr). Set at build time by `selinux-image.bbclass`, or at first boot by `selinux-autorelabel`, or any time by `restorecon -R /` |
| Processes | Inherited from parent, OR set by a `type_transition` rule when an executable runs |
| Sockets, IPC, /proc, /sys | Computed per-call by policy |

### 2.4 Operating modes

| Mode | LSM hooks called? | Denials enforced? | Denials logged? |
|---|---|---|---|
| Disabled | no | no | no |
| Permissive | yes | **no** | **yes** (to audit) |
| Enforcing | yes | yes | yes |

Switching:
- Kernel cmdline: `selinux=0` (disabled), `enforcing=0` / `enforcing=1`
- Runtime: `setenforce 0|1` (permissive ↔ enforcing only — can't go back to disabled without reboot)

```
                            reboot
                       (cmdline selinux=0)
                                ^
                                |
                     +-----------------+
                     |    Disabled     |
                     +-----------------+
                                ^
                                | reboot
                                | (cmdline removes selinux=0;
                                |  cannot leave Disabled at runtime)
                                |
       reboot                   |                  reboot
       (enforcing=0)            v                  (enforcing=1)
            +-----------------+     setenforce 1   +-----------------+
            |   Permissive    | -----------------> |   Enforcing     |
            |                 |                    |                 |
            | denials LOGGED  | <----------------- | denials LOGGED  |
            | nothing blocked |     setenforce 0   | and BLOCKED     |
            +-----------------+                    +-----------------+
```

**The bring-up loop** is: boot permissive → run real workload → collect
AVC denials with `ausearch` → write/audit2allow policy modules to cover
legitimate operations → repeat until denials stop → flip to enforcing.

### 2.5 Reference policy variants

SELinux ships with a reference policy ("refpolicy") — a big collection of
TE rules covering common Linux daemons. Variants we could pick:

| Variant | Use case |
|---|---|
| `refpolicy-minimum` | Login + getty only. Too little coverage for real systems. |
| `refpolicy-targeted` | Fedora-style: confine services, leave user shells unconfined. Common production choice. |
| `refpolicy-standard` | Full module set, no sensitivity dimension. Sensible coverage for systemd, PAM, sshd, audit, NetworkManager — but its 3-field contexts are rejected by the container runtime (see below). |
| `refpolicy-mcs` | **Our pick.** Same full module set as standard plus a single non-hierarchical sensitivity level (Multi-Category Security). |
| `refpolicy-mls` | Multi-Level Security (Bell-LaPadula). Very strict — every domain must be correctly labelled or the system won't boot. Not a fit. |

The pick lives in `edge-floor.inc`:
```
PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"
```

**Why MCS and not standard.** The container runtime (podman / netavark /
container-selinux) relabels its netns and overlay directories with
4-field contexts ending in an MCS category — e.g.
`system_u:object_r:container_file_t:s0`. A non-MCS policy has only three
context fields (user:role:type), so the kernel LSM rejects the 4-field
label at `lsetxattr()` with `EINVAL`. This is a context-*validity* check,
not an access decision, so it fires even in permissive mode — it cannot
be worked around with `--security-opt label=disable` or by setting the
policy permissive. Under `refpolicy-standard` this breaks all rootless
bridge and host networking (rootful + slirp4netns escape it only because
they skip the netns-directory relabel codepath). MCS adds the single
`s0` sensitivity level the labels require, with the same module coverage
as standard. The relabel-target types themselves (`container_file_t`,
`iptables_var_run_t`, …) are already present in refpolicy at our pin —
`iptables_var_run_t` is an alias for `iptables_runtime_t`
(`policy/modules/system/iptables.te`); the gap was always the missing
sensitivity dimension, never a missing type.

## 3. What `meta-selinux` provides

The layer is essentially three things: userspace, policy, and the bbappends
that activate libselinux in oe-core recipes.

### Userspace libraries
- `libselinux` — kernel API wrapper. Linked by systemd, PAM, busybox, etc.
- `libsemanage` — policy management
- `libsepol` — policy database parsing
- `checkpolicy` — policy-source-to-binary compiler
- `secilc` — common intermediate language compiler

### Userspace tools
- `policycoreutils` — `sestatus`, `setfiles`, `restorecon`, `fixfiles`,
  `semodule`, `semanage`, `runcon`, `secon`
- `selinux-python` — `sepolgen`, `audit2allow`, `audit2why`,
  `semanage-fcontext`. These are what you'll use daily.
- `setools` — `sesearch`, `seinfo`, `sechecker`. Advanced policy
  inspection.
- `mcstrans` — MCS/MLS label translation daemon (we don't use)
- `selinux-init`, `selinux-autorelabel`, `selinux-labeldev` — boot-time
  helpers

### Policy
- The 5 refpolicy variants above. We require `refpolicy-mcs` via
  `PREFERRED_PROVIDER_virtual/refpolicy`.

### bbclass: `selinux-image.bbclass`
Hooks `do_rootfs` to run `setfiles` against the policy's `file_contexts`
file, labelling every file at build time. **Without this class**, files
ship unlabelled (= `unlabeled_t`) and the first boot must autorelabel,
which is slow (5–15 min on a Cortex-A55 with a couple GB of rootfs).
Enabled in Phase 3 — see roadmap below.

### bbappends — 36 of them, applied automatically

This is the part of meta-selinux that does the most work for you. The
layer ships a `<recipe>_%.bbappend` for every upstream recipe that knows
how to link libselinux: `openssh`, `dbus`, `systemd`, `sudo`, `eudev`,
`util-linux`, `shadow`, `PAM`, `sysklogd`, `coreutils`, `busybox`, … and
24 more. Each bbappend is a one-liner of the form:

```bitbake
inherit ${@bb.utils.contains('DISTRO_FEATURES', 'selinux',
                              'enable-selinux enable-audit', '', d)}
```

Read that as: *"if `DISTRO_FEATURES` contains `selinux`, additionally
inherit `enable-selinux` (which flips `PACKAGECONFIG[selinux]` on for
this recipe). Otherwise, do nothing."*

The upstream recipe **already knows how to build with libselinux** —
each has a `PACKAGECONFIG[selinux] = "--with-selinux,...,libselinux,..."`
line that's just dormant until something flips it on. Meta-selinux flips
the switch.

**Practical takeaway: enabling SELinux does NOT require us to touch any
of those 36 recipes.** Two things on our side trigger all of it:

1. `meta-selinux` present in `kas/base.yml` (so bitbake sees the bbappends)
2. `DISTRO_FEATURES += " selinux"` in `edge-floor.inc` (so the bbappends
   fire)

The only recipe-level work we own is for OUR own daemons in
`meta-edge-bsp` — and that's policy authoring (Phase 4), not recipe
editing.

## 4. Daily commands

```sh
getenforce                  # Permissive | Enforcing | Disabled
sestatus                    # mode, policy variant, loaded modules
id -Z                       # your own process label
ls -Z /etc/passwd           # file label
ps auxZ | grep sshd         # subject labels of running procs
ps -eo label,pid,comm       # same, columnar

# AVC denial triage
ausearch -m AVC -ts boot              # all denials since boot
ausearch -m AVC -ts recent            # last 10 minutes
ausearch -m AVC -ts today | audit2allow -M edge-fix
   # → emits edge-fix.te (human-readable) and edge-fix.pp (binary module)
semodule -i edge-fix.pp               # install module
semodule -l | head                    # list loaded modules
semodule -r edge-fix                  # remove

# Re-apply labels
restorecon -Rv /var/log              # relabel a tree
fixfiles relabel                     # full system relabel
touch /.autorelabel ; reboot         # forced relabel on next boot

# Inspect / change policy contexts
semanage fcontext -l | grep var_log_t
semanage fcontext -a -t var_log_t '/data/log(/.*)?'   # add a rule
restorecon -Rv /data/log                              # apply it

# Per-domain permissive (only with CONFIG_SECURITY_SELINUX_DEVELOP=y)
semanage permissive -a httpd_t        # make httpd_t permissive, rest enforcing
semanage permissive -d httpd_t        # take it back to enforcing

# Toggle global mode
setenforce 0     # → Permissive
setenforce 1     # → Enforcing

# Find which rule allowed something
sesearch --allow -s sshd_t -t var_log_t
```

### The denial-triage loop

```
   daemon does something                AVC says NO
        |                                     |
        v                                     v
   +--------+   denied { ... }   +----------------+
   | kernel |  -------------->   | audit log      |
   | LSM    |                    | /var/log/audit |
   +--------+                    | + journald     |
        |                        +----------------+
        |                                |
   (permissive: continue)                |   ausearch -m AVC -ts recent
   (enforcing: EACCES)                   |
                                         v
                              +----------------------+
                              |  audit2allow -M fix  |
                              |  fix.te   (readable) |
                              |  fix.pp   (binary)   |
                              +----------------------+
                                         |
                                         v
                          +-----------------------------+
                          |  READ fix.te BEFORE         |
                          |  installing it. Three       |
                          |  decisions you might make:  |
                          |                             |
                          |  (a) right call — install:  |
                          |      semodule -i fix.pp     |
                          |                             |
                          |  (b) file label is wrong —  |
                          |      semanage fcontext -a + |
                          |      restorecon, no rule    |
                          |                             |
                          |  (c) app is misbehaving —   |
                          |      fix the app, not the   |
                          |      policy                 |
                          +-----------------------------+
```

### A worked example — a denial appears in `ausearch`

```
type=AVC msg=audit(...): avc:  denied  { read } for  pid=1234
  comm="myapp" name="config.toml" dev="mmcblk0p4" ino=98765
  scontext=system_u:system_r:edge_app_t:s0
  tcontext=system_u:object_r:data_t:s0
  tclass=file permissive=1
```

Read it as: process labelled `edge_app_t` was denied `read` on a file
labelled `data_t`. Three possible fixes:

1. **The file label is wrong** — should be `edge_app_data_t`, not
   `data_t`. Fix with `semanage fcontext -a` + `restorecon`.
2. **The label is right and the policy is missing a rule** — generate it
   with `audit2allow -a`, review the proposed `allow edge_app_t
   data_t:file read;`, install via `semodule -i`.
3. **The access is actually wrong** — your app is reading something it
   shouldn't. Fix the app, not the policy.

Always **review** `audit2allow` output before installing. Auto-allowing
everything that AVC denies defeats the point of SELinux.

## 5. Our wiring — file by file

```
   +------------------------+
   | kas/base.yml           |
   |                        |
   |   meta-selinux         |
   |   (wrynose @ pinned    |
   |    SHA, single layer)  |
   +------------------------+
              |
       +------+----------------+---------------+----------------+
       v                       v               v                v
  +---------+         +-----------+    +-----------+    +-------------+
  | distro  |         | kernel    |    | userspace |    | U-Boot env  |
  | floor   |         | fragment  |    | package   |    | defaults    |
  +---------+         +-----------+    +-----------+    +-------------+
  DISTRO_FEATURES     CONFIG_SECURITY  packagegroup-    EXTRA_KERNEL_
   += selinux          _SELINUX=y       core-selinux    ARGS=
                       _BOOTPARAM=y     refpolicy-       security=
  PREFERRED_           _DEVELOP=y       mcs              selinux
   PROVIDER_           _AVC_STATS=y     selinux-          enforcing=0
   virtual/                              autorelabel
   refpolicy =        CONFIG_DEFAULT_
   refpolicy-         _SECURITY_                        rauc_set_
   mcs                _SELINUX=y                         bootargs
                                                         appends
                      CONFIG_LSM=                        ${EXTRA_
                       "lockdown,                         KERNEL_
                        yama,bpf,                         ARGS}
                        landlock,
                        selinux"
       |                                  |
       |                                  |
       v                                  v
  triggers 36 meta-selinux bbappends     libselinux, policycoreutils,
  in oe-core/meta-oe so each gets        audit2allow, semodule, ...
  PACKAGECONFIG[selinux] (dbus,          refpolicy-mcs compiled
  eudev, openssh, sudo, util-linux,      to /etc/selinux/mcs/
  shadow, sysklogd, PAM, ...)
```

### 5.1 Kernel — `meta-edge-bsp/recipes-kernel/linux/files/cfg/security-hardening.cfg`

```
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y     # selinux=0 escape on cmdline
CONFIG_SECURITY_SELINUX_DEVELOP=y       # per-domain permissive during bring-up
CONFIG_SECURITY_SELINUX_AVC_STATS=y     # /sys/fs/selinux/avc/cache_stats
CONFIG_SECURITY_SELINUX_SIDTAB_HASH_BITS=9
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"
```

### 5.2 Distro — `meta-edge-distro/conf/distro/include/edge-floor.inc`

```
DISTRO_FEATURES = "... selinux ..."
PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"
```

When `DISTRO_FEATURES` contains `selinux`, oe-core's systemd recipe
(plus 24 other recipes) flips its PACKAGECONFIG to build with
libselinux, and meta-selinux's bbappends activate.

### 5.3 Userspace — `meta-edge-bsp/recipes-core/packagegroups/packagegroup-edge-security.bb`

```
RDEPENDS:${PN} += "packagegroup-core-selinux refpolicy-mcs selinux-autorelabel"
```

`packagegroup-core-selinux` pulls libselinux, libsemanage, libsepol,
policycoreutils, restorecond, setools, mcstrans, semodule-utils.

`refpolicy-mcs` builds and installs the policy modules. This is a
*concrete* package name, not the `virtual/refpolicy` alias — it must be
kept in sync with `PREFERRED_PROVIDER_virtual/refpolicy` in
`edge-floor.inc`. A mismatch builds both policy variants into the image.

`selinux-autorelabel` is the systemd unit that runs `restorecon -R /` on
first boot when `/.autorelabel` exists, then deletes the marker.

### 5.4 Kernel cmdline — `meta-edge-bsp/recipes-bsp/u-boot/files/rauc-uboot-env.defaults`

```
rauc_set_bootargs=... ${EXTRA_KERNEL_ARGS}; echo "[RAUC] ..."
EXTRA_KERNEL_ARGS=security=selinux enforcing=0
```

`security=selinux` activates the LSM. `enforcing=0` starts permissive.
The migration stamp in `rauc-uboot-env-init.sh` is bumped to
`v4-selinux` so already-flashed boards re-migrate the env on next boot.

### 5.5 Layer — `kas/base.yml`

```yaml
meta-selinux:
  url: https://git.yoctoproject.org/meta-selinux
  branch: wrynose
  commit: 1c3a699f363167571ab39fecb0fe6f56691a4e20
  layers:
    .:
```

Pinned by SHA. Bump deliberately on the sustaining cycle, not by drift.

## 6. Verifying after the rebuild

On the live board, after flashing the new image:

```sh
# Kernel side
zcat /proc/config.gz | grep -E "SECURITY_SELINUX|DEFAULT_SECURITY|CONFIG_LSM"
cat /proc/cmdline    # expect "security=selinux enforcing=0"

# Userspace side
which sestatus       # /usr/sbin/sestatus
sestatus             # mode + policy + loaded modules
mount | grep selinuxfs   # /sys/fs/selinux ... selinuxfs (...)
ls /sys/fs/selinux/  # avc, booleans, class, policy, status, ...
getenforce           # Permissive
id -Z                # your own label

# Audit pipeline
systemctl status auditd
ausearch -m AVC -ts boot | wc -l   # >0 expected; permissive logs denials
systemctl --failed                  # empty (everything still works)
```

## 7. Recovery

### Bad policy blocks something critical, system still boots
```sh
setenforce 0          # back to permissive
# fix policy, then
setenforce 1
```

### Bad policy prevents booting
**From U-Boot console:**
```
setenv EXTRA_KERNEL_ARGS 'security=selinux selinux=0'
saveenv
reset
```

**Or, for a single boot, append to cmdline at boot menu:**
```
selinux=0
```

This disables SELinux for that boot only. Investigate, regenerate
policy, drop `selinux=0`, reboot.

### Re-label is corrupted or wrong
```sh
touch /.autorelabel
reboot
# selinux-autorelabel.service runs `restorecon -R /` on next boot
```

## 8. Roadmap — what isn't in Phases 1+2

### Phase 3 — label at build, OTA integration
- `IMAGE_CLASSES:append = " selinux-image"` in `edge-floor.inc` — runs
  `setfiles` at `do_rootfs`. Saves 5–15 min on first boot.
- `meta-edge-bsp/recipes-ota/rauc/files/bundle-hooks.sh` post-install
  hook: `touch "${RAUC_SLOT_MOUNT}/.autorelabel"` so OTA-installed slots
  relabel on their first boot.

### Phase 4 — enforce
- Flip `EXTRA_KERNEL_ARGS=security=selinux enforcing=1` in prod tier.
- Drop `CONFIG_SECURITY_SELINUX_DEVELOP=y` from the prod fragment to
  remove the per-domain permissive override surface.
- Custom policy modules for our own daemons (edge-banner,
  edge-pstore-prune, edge-persistence services, weston) as their
  domains stabilize.

## 9. References

- [SELinux Project wiki](https://github.com/SELinuxProject/selinux/wiki)
- [The SELinux Notebook](https://github.com/SELinuxProject/selinux-notebook)
  — best deep-dive reference
- [Reference Policy](https://github.com/SELinuxProject/refpolicy) — the
  source of `refpolicy-mcs`
- `meta-selinux/SELinux-FAQ` in our pinned layer — short FAQ shipped with
  the layer itself
- `meta-selinux/README` — layer's own integration notes

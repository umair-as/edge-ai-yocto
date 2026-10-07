# Provider-neutral kernel policy for the edge-ai distro.
#
# Every kernel provider bbappend requires this file. The fragments below
# are platform floor, not board content: module signing, dm-verity, the
# SELinux LSM stack and CONFIG_LSM ordering, lockdown, IMA/EVM, RAUC
# verity, dm-crypt, container cgroups and storage/net, AI compute,
# hwcrypto/RNG and pstore. Board-specific fragments and DTS patches stay
# in the provider bbappend behind a machine override. The dev-tier and
# opt-in toggles (EDGE_KERNEL_DEV_FRAGMENTS, EDGE_ENABLE_BTF_CORE_DEV,
# EDGE_ENABLE_JTAG_DEBUG) and the kernel -src packaging policy live here
# too: they read the same fragment set and apply to every provider.
#
# do_kernel_configme resolves these into .config; the assertion at the
# bottom of this file is what makes a dropped symbol a build failure
# rather than a warning. kernel-yocto.bbclass reports a fragment naming
# a symbol the target kernel does not have only when
# KCONF_BSP_AUDIT_LEVEL is non-zero (it defaults to 0), and a requested
# symbol that never reaches .config only as a bb.warn.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://cfg/rauc-verity.cfg \
    file://cfg/hwcrypto-hwrng.cfg \
    file://cfg/dm-crypt.cfg \
    file://cfg/containers-cgroups.cfg \
    file://cfg/container-storage-net.cfg \
    file://cfg/ai-compute.cfg \
    file://cfg/security-hardening.cfg \
    file://cfg/pstore-persist.cfg \
"

SRC_URI:append = "${@' file://cfg/nfs-off.cfg' if d.getVar('EDGE_DEV_NETBOOT') != '1' else ''}"

# Publish linux.bin + linux_comp into DEPLOY_DIR_IMAGE. Wrynose split FIT
# generation into two stages: the kernel recipe publishes raw artifacts,
# edge-kernel-fit consumes them to assemble and sign the FIT.
KERNEL_CLASSES:append = " kernel-fit-extra-artifacts"

# Dev-only fragments. Tier defaults live in edge-profile-{dev,prod}.inc;
# this fallback keeps them on for builds that do not use the edge-ai distro.
EDGE_KERNEL_DEV_FRAGMENTS ?= "1"
SRC_URI:append = "${@' file://cfg/observability-dev.cfg file://cfg/crash-debug-dev.cfg' if d.getVar('EDGE_KERNEL_DEV_FRAGMENTS') == '1' else ''}"

# BTF/CO-RE — independent, OFF by default. btf-core-dev.cfg turns on in-kernel
# BTF (CONFIG_DEBUG_INFO_BTF + _MODULES) over un-reduced DWARF; the build runs
# pahole to emit the .BTF section. Three things are required, all gated together:
#   - btf-core-dev.cfg (the CONFIG_* request)
#   - pahole-native in DEPENDS (meta-oe pahole v1.31; the generator)
#   - KERNEL_DEBUG="True", which makes linux-yocto.inc drop its default
#     `PAHOLE=false` from the config-time make and add pahole-native to
#     do_kernel_configme. Without it, CONFIG_PAHOLE_VERSION probes `false`,
#     resolves to 0, and Kconfig silently drops DEBUG_INFO_BTF even though
#     pahole is in the sysroot.
# Un-reduced DWARF + per-module BTF inflate /lib/modules and the OTA bundle, so
# this is its own gate (separate from JTAG): off for DRP-AI/edge-AI builds, on
# only for libbpf/CO-RE labs.
EDGE_ENABLE_BTF_CORE_DEV ?= "0"
SRC_URI:append = "${@' file://cfg/btf-core-dev.cfg' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"
DEPENDS:append = "${@' pahole-native' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"
KERNEL_DEBUG = "${@'True' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"

# JTAG/OpenOCD source-level kernel-debug fragment — opt-in, off by default.
# Appended last so its KASLR/lockup-detector overrides win the merge over
# crash-debug-dev.cfg. do_kernel_configcheck flags those two symbols as a
# requested-vs-final mismatch; that is the intended override, not an error.
EDGE_ENABLE_JTAG_DEBUG ?= "0"
SRC_URI:append = "${@' file://cfg/jtag-debug.cfg' if d.getVar('EDGE_ENABLE_JTAG_DEBUG') == '1' else ''}"

# Generate the in-tree gdb helpers' constants.py (lx-ps, lx-dmesg, lx-symbols).
# CONFIG_GDB_SCRIPTS=y (jtag-debug.cfg) builds the infra, but constants.py is
# only produced by `make scripts_gdb`; without it `source vmlinux-gdb.py` fails
# with "No module named 'linux'". Emitted into ${B}/scripts/gdb/ for the host
# debugger to source. Gated on the JTAG toggle — no cost on normal builds.
do_compile:append() {
    if [ "${EDGE_ENABLE_JTAG_DEBUG}" = "1" ]; then
        oe_runmake scripts_gdb
    fi
}

# No kernel -src package.
#
# oe-core defaults PACKAGE_DEBUG_SPLIT_STYLE to "debug-with-srcpkg"
# (bitbake.conf:331), the only value that populates ${PN}-src
# (package.bbclass:448). For the kernel that package is ~1.6G of sources that
# nothing can install: src-pkgs is not in IMAGE_FEATURES anywhere here, and a
# dm-verity root could not take them anyway. It also fails buildpaths QA,
# because generated sources such as drivers/tty/vt/consolemap_deftbl.c carry
# the absolute path of their input in a comment emitted by conmakehash.
#
# Dropping it removes the package rather than excusing it; -dbg is unaffected,
# so EDGE_DEV_DBG_PKGS still works. Kernel source for host-side debugging
# stays in work-shared/${MACHINE}/kernel-source, which rm_work preserves.
PACKAGE_DEBUG_SPLIT_STYLE = "debug-without-src"

# Load-bearing symbols asserted against the resolved .config. Each entry
# is matched as an exact line, so a value change (CONFIG_LSM ordering) is
# caught as well as a missing symbol. Extend per provider via
# EDGE_KERNEL_POLICY_EXTRA_CONFIG, one CONFIG_ line per space-separated
# entry (values containing spaces are not expressible there).
EDGE_KERNEL_POLICY_EXTRA_CONFIG ?= ""

python do_edge_kernel_policy_assert() {
    import os

    required = [
        'CONFIG_MODULE_SIG_FORCE=y',
        'CONFIG_DM_VERITY=y',
        'CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG=y',
        'CONFIG_CRYPTO_SHA256=y',
        'CONFIG_SECURITY_SELINUX=y',
        'CONFIG_SECURITY_LOCKDOWN_LSM=y',
        'CONFIG_LSM="lockdown,yama,landlock,selinux,bpf"',
    ]
    required += (d.getVar('EDGE_KERNEL_POLICY_EXTRA_CONFIG') or '').split()

    config = os.path.join(d.getVar('B'), '.config')
    if not os.path.exists(config):
        bb.fatal('edge kernel policy: no resolved .config at %s' % config)

    with open(config) as f:
        present = set(line.strip() for line in f)

    # Every name in CONFIG_LSM must also have its own enabling symbol.
    # Naming an LSM in the list does not build it: an unbuilt LSM is
    # simply absent from /sys/kernel/security/lsm at runtime, with
    # nothing at build time saying so. Derived from the resolved
    # CONFIG_LSM rather than a second hardcoded list, so the two cannot
    # drift apart.
    lsm_symbol = {
        'lockdown':  'CONFIG_SECURITY_LOCKDOWN_LSM=y',
        'yama':      'CONFIG_SECURITY_YAMA=y',
        'bpf':       'CONFIG_BPF_LSM=y',
        'landlock':  'CONFIG_SECURITY_LANDLOCK=y',
        'selinux':   'CONFIG_SECURITY_SELINUX=y',
        'apparmor':  'CONFIG_SECURITY_APPARMOR=y',
        'smack':     'CONFIG_SECURITY_SMACK=y',
        'tomoyo':    'CONFIG_SECURITY_TOMOYO=y',
        'safesetid': 'CONFIG_SECURITY_SAFESETID=y',
        'ima':       'CONFIG_IMA=y',
        'evm':       'CONFIG_EVM=y',
        'capability': None,   # always built in when CONFIG_SECURITY=y
    }
    unknown = []
    for line in present:
        if not line.startswith('CONFIG_LSM='):
            continue
        for name in line.split('=', 1)[1].strip('"').split(','):
            name = name.strip()
            if not name:
                continue
            if name not in lsm_symbol:
                unknown.append(name)
            elif lsm_symbol[name]:
                required.append(lsm_symbol[name])

    if unknown:
        bb.fatal(
            'edge kernel policy: CONFIG_LSM names %s, which this check has '
            'no enabling symbol for. Add it to lsm_symbol in '
            'edge-kernel-policy.inc so the LSM is verified to be built, not '
            'merely requested.' % ', '.join(sorted(set(unknown))))

    required = list(dict.fromkeys(required))   # de-dup, keep order
    missing = [entry for entry in required if entry not in present]
    if missing:
        bb.fatal(
            'edge kernel policy: %d required symbol(s) absent from the '
            'resolved .config:\n  %s\n'
            'The fragment list in edge-kernel-policy.inc requested these, '
            'but they are absent from the .config that %s will build.\n'
            'A fragment naming a symbol this kernel does not have is silent '
            'by default (KCONF_BSP_AUDIT_LEVEL defaults to 0), so check the '
            'symbol names against this kernel version before changing the list.'
            % (len(missing), '\n  '.join(missing), d.getVar('PN')))
}

# Ordered after do_configure, not after do_kernel_configme: kernel.bbclass
# runs KERNEL_CONFIG_COMMAND (olddefconfig) in do_configure, which re-resolves
# .config and drops symbols whose dependencies are unmet. Asserting between
# configme and configure would read a .config that is not the one built.
addtask edge_kernel_policy_assert after do_configure before do_compile
do_edge_kernel_policy_assert[dirs] = "${B}"

# KSPP baseline gate on the prod kernel. kernel-hardening-checker, from the
# native sysroot, runs against the resolved .config; any failure the board's
# baseline (files/khc/<board>-prod.baseline.json) does not accept with a
# reason, and a baseline recorded with another checker version, fail the
# build before compilation. The dev kernel carries debug fragments and is
# not under claim, so it is not gated. The assertion above is independent of
# this gate: a baseline entry cannot waive a required symbol.
#
# Gate script and baseline enter the task signature by checksum, so editing
# either re-runs the gate and everything after it. EDGE_KHC_BOARD is the
# kas/machines/<name>.yml name, set by the board include; the snapshot of
# the same .config lives in docs/security/kernel-config/.
EDGE_KHC_BOARD ?= ""
EDGE_KHC_GATE = "${@'1' if d.getVar('EDGE_KERNEL_DEV_FRAGMENTS') != '1' else '0'}"
EDGE_KHC_DIR = "${EDGE_BSP_LAYERDIR}/recipes-kernel/linux/files/khc"
EDGE_KHC_BASELINE = "${EDGE_KHC_DIR}/${EDGE_KHC_BOARD}-prod.baseline.json"
DEPENDS:append = "${@' kernel-hardening-checker-native python3-native' if d.getVar('EDGE_KHC_GATE') == '1' else ''}"

python do_edge_khc_gate() {
    import os
    import subprocess

    if d.getVar('EDGE_KHC_GATE') != '1':
        bb.note('edge khc gate: dev kernel (EDGE_KERNEL_DEV_FRAGMENTS=1), not gated')
        return
    board = d.getVar('EDGE_KHC_BOARD')
    if not board:
        bb.fatal('edge khc gate: EDGE_KHC_BOARD is empty; set it in '
                 'conf/machine/include/edge-board-%s.inc' % d.getVar('MACHINE'))
    baseline = d.getVar('EDGE_KHC_BASELINE')
    if not os.path.exists(baseline):
        bb.fatal('edge khc gate: no baseline for board %s at %s' % (board, baseline))

    b = d.getVar('B')
    report = os.path.join(b, 'khc-report.md')
    cmd = [os.path.join(d.getVar('STAGING_BINDIR_NATIVE'), 'python3-native', 'python3'),
           os.path.join(d.getVar('EDGE_KHC_DIR'), 'khc-gate.py'),
           '--config', os.path.join(b, '.config'),
           '--baseline', baseline,
           '--report', report]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        bb.note(line)
    if r.returncode != 0:
        bb.fatal('edge khc gate: the resolved .config fails the KSPP baseline for '
                 '%s (rc=%d).\n%s\nReport: %s\nAccept a failure only with a reason in '
                 '%s; a mandatory symbol is asserted separately above.'
                 % (board, r.returncode, (r.stdout + r.stderr).strip(), report, baseline))
}
addtask edge_khc_gate after do_edge_kernel_policy_assert before do_compile
do_edge_khc_gate[dirs] = "${B}"
do_edge_khc_gate[file-checksums] += "${@'%s/khc-gate.py:True %s:True' % (d.getVar('EDGE_KHC_DIR'), d.getVar('EDGE_KHC_BASELINE')) if d.getVar('EDGE_KHC_GATE') == '1' else ''}"

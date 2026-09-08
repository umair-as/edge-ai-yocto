# Provider-neutral kernel policy for the edge-ai distro.
#
# Every kernel provider bbappend requires this file. The fragments below
# are platform floor, not board content: module signing, dm-verity, the
# SELinux LSM stack and CONFIG_LSM ordering, lockdown, IMA/EVM, RAUC
# verity, dm-crypt, container cgroups and storage/net, AI compute,
# hwcrypto/RNG and pstore. Board-specific fragments and DTS patches stay
# in the provider bbappend behind a machine override.
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

# Publish linux.bin + linux_comp into DEPLOY_DIR_IMAGE. Wrynose split FIT
# generation into two stages: the kernel recipe publishes raw artifacts,
# edge-kernel-fit consumes them to assemble and sign the FIT.
KERNEL_CLASSES:append = " kernel-fit-extra-artifacts"

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
        'CONFIG_SECURITY_SELINUX=y',
        'CONFIG_SECURITY_LOCKDOWN_LSM=y',
        'CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"',
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

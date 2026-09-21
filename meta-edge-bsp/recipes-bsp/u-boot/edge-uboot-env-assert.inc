# Shared by every U-Boot bbappend: the board include declares the raw env
# area and the resolved .config must agree with it.
# Assert the board's declared env area against the resolved U-Boot .config.
#
# EDGE_UBOOT_ENV_* (board include) tells userspace where the raw environment
# lives; CONFIG_ENV_OFFSET / _OFFSET_REDUND / _SIZE tell U-Boot the same
# thing. Nothing couples them, and a mismatch is invisible: the board boots,
# fw_setenv writes to an area U-Boot does not read, and RAUC's boot-count
# silently never persists -- so a failed update never rolls back. Ordered
# after do_configure because that is where the defconfig plus fragments
# resolve into .config.
python edge_assert_uboot_env_offsets() {
    import os, re
    want = {
        'CONFIG_ENV_OFFSET':        d.getVar('EDGE_UBOOT_ENV_OFFSET'),
        'CONFIG_ENV_OFFSET_REDUND': d.getVar('EDGE_UBOOT_ENV_OFFSET_REDUND'),
        'CONFIG_ENV_SIZE':          d.getVar('EDGE_UBOOT_ENV_SIZE'),
    }
    missing = [k for k, v in want.items() if not v]
    if missing:
        bb.fatal("Board declares no value for: %s. Set them in "
                 "conf/machine/include/edge-board-%s.inc."
                 % (' '.join(missing), d.getVar('MACHINE')))

    b = d.getVar('B')
    configs = []
    for root, _dirs, files in os.walk(b):
        if '.config' in files:
            configs.append(os.path.join(root, '.config'))
    if not configs:
        bb.fatal("No resolved .config under %s; cannot verify the env area." % b)

    problems = []
    for cfg in configs:
        with open(cfg) as fh:
            text = fh.read()
        for sym, expect in want.items():
            m = re.search(r'^%s=(\S+)$' % sym, text, re.M)
            if not m:
                problems.append("%s: %s absent" % (cfg, sym))
                continue
            got = m.group(1)
            if int(got, 0) != int(expect, 0):
                problems.append("%s: %s is %s, board declares %s"
                                % (cfg, sym, got, expect))
    if problems:
        bb.fatal(
            "U-Boot environment area disagrees with the board include:\n  %s\n"
            "  fw_setenv would write where U-Boot does not read, so RAUC's\n"
            "  boot-count would never persist and a failed update would never\n"
            "  roll back. Fix the board include or the U-Boot env patch so the\n"
            "  two agree." % "\n  ".join(problems))
    bb.note("U-Boot env area matches the board include in %d .config file(s)"
            % len(configs))
}
do_configure[postfuncs] += "edge_assert_uboot_env_offsets"
edge_assert_uboot_env_offsets[vardeps] += "EDGE_UBOOT_ENV_OFFSET \
    EDGE_UBOOT_ENV_OFFSET_REDUND EDGE_UBOOT_ENV_SIZE"

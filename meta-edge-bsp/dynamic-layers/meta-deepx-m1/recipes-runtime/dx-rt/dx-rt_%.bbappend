# wrynose source layout: the recipe's S = "${WORKDIR}/git" is a hard QA error
# since oe-core dropped the source-move shim. Restated because a bbappend
# cannot delete the recipe's assignment.
S = "${UNPACKDIR}/${BP}"

# No SysV script: the distro has no sysvinit, so the update-rc.d hook is
# inert and the installed script would never run. dxrtd is started by
# dxrtd.service from edge-dxm1-runtime.
do_install:append() {
    rm -f ${D}${sysconfdir}/init.d/dxrt-init
    rmdir --ignore-fail-on-non-empty ${D}${sysconfdir}/init.d 2>/dev/null || true
}
FILES:${PN}-cli:remove = "${sysconfdir}/init.d/dxrt-init"

# The pip build-isolation fix is a kas patch on the layer
# (kas/patches/meta-deepx-m1/0002-dx-rt-no-build-isolation.patch): the flag
# has to go inside upstream's pip invocation. PIP_NO_BUILD_ISOLATION in the
# task environment does not work.

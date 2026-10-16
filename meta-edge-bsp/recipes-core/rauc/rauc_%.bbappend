# RAUC daemon RDEPENDS. The first-boot /data grow oneshot moved to the
# edge-grow-data recipe (one mechanism for both eSD/MBR and eMMC/GPT).
RDEPENDS:${PN} += "lvm2"

# Upstream fix for boot-emmc slot hooks (rauc a75bbb2b), merged after
# v1.15.2. Drop the patch and the PR suffix with the first meta-rauc wrynose
# RAUC release that contains it.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://0001-src-update_handler-fix-assertion-slot-name-failed-er.patch"
# Package revision marks the patched build on the target (rpm -q rauc).
PR:append = ".edge1"

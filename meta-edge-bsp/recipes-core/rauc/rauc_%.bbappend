# RAUC daemon RDEPENDS. The first-boot /data grow oneshot moved to the
# edge-grow-data recipe (one mechanism for both eSD/MBR and eMMC/GPT).
RDEPENDS:${PN} += "lvm2"

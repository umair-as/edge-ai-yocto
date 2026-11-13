# 60-fastrpc.rules grants the fastrpc group the DMA heap through
# /bin/setfacl; without acl the RUN fails and the heap stays root-only.
RDEPENDS:${PN} += "acl"

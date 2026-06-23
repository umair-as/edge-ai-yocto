# meta-virtualization's container-host-config ships storage.conf with
# driver = "vfs" (build-time workaround for assembly under pseudo/fakeroot).
# Edge runs native overlay on the /data graphroot; shadow the file via
# this layer's files/ dir so the base recipe installs this copy.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

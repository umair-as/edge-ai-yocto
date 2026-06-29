SUMMARY     = "eBPF / CO-RE lab userspace tooling"
DESCRIPTION = "bpftool for BTF inspection and BPF program/map introspection. \
The userspace half of the libbpf CO-RE labs; pairs with the kernel BTF enabled \
by EDGE_ENABLE_BTF_CORE_DEV."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "devel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# bpftool is built from the kernel source — machine-arch, not allarch. Set
# before inherit so packagegroup.bbclass does not pull in allarch.
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# bpftrace + bcc + a CO-RE compiler (clang/libbpf) join here when the 6a/6b
# labs are wired; they drag in LLVM, so they stay out until needed.
RDEPENDS:${PN} = " \
    bpftool \
"

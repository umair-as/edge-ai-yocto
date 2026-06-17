SUMMARY     = "Shell QoL: editors, multiplexers, common CLI"
DESCRIPTION = "Interactive shell userspace for dev/bring-up tiers: vim, nano, \
tmux, screen, less, file, jq, tree, curl, wget, rsync, bash-completion. \
Not in the prod tier."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
RDEPENDS:${PN} = " \
    vim \
    nano \
    tmux \
    screen \
    less \
    file \
    jq \
    bash-completion \
    curl \
    wget \
    tree \
    rsync \
"

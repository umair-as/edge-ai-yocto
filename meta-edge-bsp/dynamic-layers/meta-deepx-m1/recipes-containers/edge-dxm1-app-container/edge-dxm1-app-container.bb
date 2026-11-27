SUMMARY     = "OCI image: DX-M1 inference runner with its DXRT client runtime"
DESCRIPTION = "Application container built in the same build as the host dx-rt, so \
the libdxrt inside matches the host dxrtd and driver. Carries no model: the \
model is bind-mounted from /data (ADR-0010)."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

IMAGE_FSTYPES = "container oci"
inherit image image-oci

IMAGE_FEATURES = ""
IMAGE_LINGUAS = ""
NO_RECOMMENDATIONS = "1"
# image-container.bbclass requires linux-dummy as the kernel provider unless
# this is set; an application image carries no kernel either way.
IMAGE_CONTAINER_NO_DUMMY = "1"

IMAGE_INSTALL = "base-files base-passwd dx-rt-cli"

OCI_IMAGE_ENTRYPOINT = "/usr/bin/run_model"
OCI_IMAGE_CMD = "-m /models/model.dxnn -b"
OCI_IMAGE_WORKINGDIR = "/tmp"
# Must match dxrtd.service in edge-dxm1-runtime (docs/dxm1/integration-notes.md).
OCI_IMAGE_ENV_VARS = "DXRT_DYNAMIC_IPC_ENDPOINT=/run/dxrt/ipc.sock"

# edge-users.inc provisions host accounts in every image (INHERIT extrausers):
# the devel login, root's password, edge-ctr group joins, subid ranges. None
# of it belongs in an application image, and the edge-ctr joins fail here.
EXTRA_USERS_PARAMS = ""
EDGE_ACCEL_SUPPLEMENTARY_GROUPS = ""
EDGE_BOARD_DEVEL_GROUPS = ""
EDGE_MACHINE_EXTRA_INSTALL = ""
EDGE_DEVEL_SSH_PUBKEY_FILE = ""
ROOTFS_POSTUNINSTALL_COMMAND:remove = "edge_write_subid_ranges;"

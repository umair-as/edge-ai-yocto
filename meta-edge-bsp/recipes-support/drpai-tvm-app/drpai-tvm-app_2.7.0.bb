SUMMARY     = "DRP-AI TVM tutorial inference app (ImageNet classifier) for RZ/V2L"
DESCRIPTION = "Minimal DRP-AI TVM (RUHMI) classification application for RZ/V2L: \
loads a DRP-AI-compiled model, runs the DRP-AI pre-processing + inference path \
over /dev/drpai0 and udmabuf, and prints the top results. Built from the v2ml \
(CPU-mode) tutorial source against the prebuilt runtime."
HOMEPAGE    = "https://github.com/renesas-rz/rzv_drp-ai_tvm"
SECTION     = "console/utils"
LICENSE     = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=0ba5044c64ef53cb0189c9546081e228"
BUGTRACKER  = "https://github.com/renesas-rz/rzv_drp-ai_tvm/issues"

require recipes-support/drpai-tvm/drpai-tvm-src.inc
SRC_URI = "${DRPAI_TVM_GIT}"
SRCREV  = "${DRPAI_TVM_SRCREV}"

COMPATIBLE_MACHINE = "smarc-rzv2l"

# tvm/dlpack/dmlc/builtin_fp16.h headers come from drpai-tvm-runtime -dev;
# linux/drpai.h from kernel-module-drpai -dev; spdlog (+ external fmt) for the
# runtime wrapper. meta-oe builds spdlog with SPDLOG_FMT_EXTERNAL, so the bundled
# fmt headers are absent — the consumer must mirror that define and link fmt.
DEPENDS = "drpai-tvm-runtime kernel-module-drpai spdlog fmt asio"

# V2L shares the v2m runtime; the v2ml source path uses CPU-mode dispatch.
do_compile() {
    cd ${S}/apps
    ${CXX} ${CXXFLAGS} ${LDFLAGS} -std=c++17 -O3 \
        -DMERA_DRP_RUNTIME -DKDLCPUMODE -DSPDLOG_FMT_EXTERNAL \
        -I${S}/apps/include \
        -I${RECIPE_SYSROOT}${includedir} \
        tutorial_app_v2ml.cpp MeraDrpRuntimeWrapper.cpp PreRuntime.cpp \
        -lmera2_runtime -lmera2_plan_io -ldrp_tvm_rt -lspdlog -lfmt -lpthread \
        -o drpai-tutorial-app
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/apps/drpai-tutorial-app ${D}${bindir}/
}

FILES:${PN} = "${bindir}/drpai-tutorial-app"
RDEPENDS:${PN} = "drpai-tvm-runtime"

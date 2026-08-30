SUMMARY     = "DRP-AI recon tools: model benchmark and real-input classifier"
DESCRIPTION = "Two host-staged tools for any DRP-AI-compiled model directory: \
drpai-runner times inference with an NPU-IRQ witness and optional per-operator \
profiling, drpai-classify feeds a real image and decodes a classification result."
HOMEPAGE    = "https://github.com/renesas-rz/rzv_drp-ai_tvm"
SECTION     = "console/utils"
LICENSE     = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=0ba5044c64ef53cb0189c9546081e228"
BUGTRACKER  = "https://github.com/renesas-rz/rzv_drp-ai_tvm/issues"

# MeraDrpRuntimeWrapper.cpp is fetched at the shared pin (matches drpai-tvm-runtime);
# drpai_runner.cpp is the local benchmark driver.
require recipes-support/drpai-tvm/drpai-tvm-src.inc
SRC_URI = "${DRPAI_TVM_GIT} \
           file://drpai_runner.cpp \
           file://drpai_classify.cpp"
SRCREV  = "${DRPAI_TVM_SRCREV}"

COMPATIBLE_MACHINE = "smarc-rzv2l"

# Recon and measurement tools, deliberately outside packagegroup-edge-ai: staged by
# hand for a measurement session, not shipped in the image and not the production
# inference path. drpai-classify handles classification only.

# tvm/dlpack/dmlc/builtin_fp16.h from drpai-tvm-runtime -dev; linux/drpai.h from
# kernel-module-drpai -dev; spdlog (external fmt) + asio for the runtime wrapper.
DEPENDS = "drpai-tvm-runtime kernel-module-drpai spdlog fmt asio"

do_compile() {
    # DEBUG_PREFIX_MAP: a raw ${CXX} call doesn't inherit it; without it the
    # -dbg package fails do_package_qa [buildpaths] on embedded TMPDIR paths.
    # DEBUG_PREFIX_MAP only maps ${S} (the git checkout); the file:// runner source
    # lands in ${UNPACKDIR} one level up, so map that too or its debug path leaks.
    ${CXX} ${CXXFLAGS} ${LDFLAGS} ${DEBUG_PREFIX_MAP} \
        -ffile-prefix-map=${UNPACKDIR}=/usr/src/debug/${PN}/${PV} -std=c++20 -O3 \
        -DMERA_DRP_RUNTIME -DKDLCPUMODE -DSPDLOG_FMT_EXTERNAL \
        -I${S}/apps -I${S}/apps/include \
        -I${RECIPE_SYSROOT}${includedir} \
        ${UNPACKDIR}/drpai_runner.cpp ${S}/apps/MeraDrpRuntimeWrapper.cpp \
        -lmera2_runtime -lmera2_plan_io -ldrp_tvm_rt -lspdlog -lfmt -lpthread \
        -o ${B}/drpai-runner

    # Real-input companion. Adds PreRuntime (the DRP-AI pre-processing engine the
    # runtime has no API to describe) and builds at c++17 to match the vendor
    # sources it links.
    ${CXX} ${CXXFLAGS} ${LDFLAGS} ${DEBUG_PREFIX_MAP} \
        -ffile-prefix-map=${UNPACKDIR}=/usr/src/debug/${PN}/${PV} -std=c++17 -O3 \
        -DMERA_DRP_RUNTIME -DKDLCPUMODE -DSPDLOG_FMT_EXTERNAL \
        -I${S}/apps -I${S}/apps/include \
        -I${RECIPE_SYSROOT}${includedir} \
        ${UNPACKDIR}/drpai_classify.cpp ${S}/apps/MeraDrpRuntimeWrapper.cpp \
        ${S}/apps/PreRuntime.cpp \
        -lmera2_runtime -lmera2_plan_io -ldrp_tvm_rt -lspdlog -lfmt -lpthread \
        -o ${B}/drpai-classify
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/drpai-runner ${D}${bindir}/
    install -m 0755 ${B}/drpai-classify ${D}${bindir}/
}

FILES:${PN} = "${bindir}/drpai-runner ${bindir}/drpai-classify"
RDEPENDS:${PN} = "drpai-tvm-runtime"

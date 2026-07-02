SUMMARY     = "Model-agnostic DRP-AI inference runner + benchmark for RZ/V2L"
DESCRIPTION = "Loads any DRP-AI-compiled model directory, reads its input tensor \
from the runtime, feeds a synthetic input, and times inference over N iterations \
with an NPU-IRQ witness. Carries no baked model. Optional per-operator profiling."
HOMEPAGE    = "https://github.com/renesas-rz/rzv_drp-ai_tvm"
SECTION     = "console/utils"
LICENSE     = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=0ba5044c64ef53cb0189c9546081e228"
BUGTRACKER  = "https://github.com/renesas-rz/rzv_drp-ai_tvm/issues"

# MeraDrpRuntimeWrapper.cpp is fetched at the pinned tag (matches drpai-tvm-runtime);
# drpai_runner.cpp is the local benchmark driver.
SRC_URI = "git://github.com/renesas-rz/rzv_drp-ai_tvm.git;protocol=https;branch=main \
           file://drpai_runner.cpp"
SRCREV  = "110048ecadc6a997628d9a79024b9d59ae2ef7ea"

COMPATIBLE_MACHINE = "smarc-rzv2l"

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
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/drpai-runner ${D}${bindir}/
}

FILES:${PN} = "${bindir}/drpai-runner"
RDEPENDS:${PN} = "drpai-tvm-runtime"

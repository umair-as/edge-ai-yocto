SUMMARY     = "DRP-AI TVM (RUHMI) on-device inference runtime for RZ/V2L"
DESCRIPTION = "Prebuilt EdgeCortix MERA / DRP-AI TVM runtime shared libraries \
that execute DRP-AI-compiled models on RZ/V2L through /dev/drpai0 and the mmngr \
buffer path, plus the matching TVM runtime headers (-dev) to build applications \
against the runtime. The V2L target uses the v2m runtime build."
HOMEPAGE    = "https://github.com/renesas-rz/rzv_drp-ai_tvm"
SECTION     = "libs"
LICENSE     = "Apache-2.0"
LIC_FILES_CHKSUM = " \
    file://LICENSE;md5=0ba5044c64ef53cb0189c9546081e228 \
    file://tvm/LICENSE;md5=6ec4db95cc43836f5e2ff1d6edaa2284 \
"
BUGTRACKER  = "https://github.com/renesas-rz/rzv_drp-ai_tvm/issues"

# The prebuilt repo is library-only. Headers to compile against the runtime
# (tvm/runtime/*, dlpack, dmlc, builtin_fp16.h) live only in the pinned
# apache/tvm v0.8 submodule it references; fetched here at the same pins.
SRC_URI = " \
    git://github.com/renesas-rz/rzv_drp-ai_tvm.git;protocol=https;branch=main;name=rt;destsuffix=tvmrt \
    git://github.com/apache/tvm.git;protocol=https;nobranch=1;name=tvm;destsuffix=tvmrt/tvm \
    git://github.com/dmlc/dlpack.git;protocol=https;nobranch=1;name=dlpack;destsuffix=tvmrt/tvm/3rdparty/dlpack \
    git://github.com/dmlc/dmlc-core.git;protocol=https;nobranch=1;name=dmlc;destsuffix=tvmrt/tvm/3rdparty/dmlc-core \
"
# rt: Release-2026-04-17 (DRP-AI TVM v2.7.0-hotfix2 / RUHMI R2026-04, mera2 2.5.1).
# The model-compile environment (rzv2l-drpai-compile-env) must pin this same
# release — the EdgeCortix runtime/compiler ABI is release-coupled; bump both.
SRCREV_rt     = "110048ecadc6a997628d9a79024b9d59ae2ef7ea"
# tvm + nested gitlinks the prebuilt repo pins at SRCREV_rt
SRCREV_tvm    = "046910a4100c5a822133ade5dfe851a1eb0ad95a"
SRCREV_dlpack = "e2bdd3bee8cb6501558042633fa59144cc8b7f5f"
SRCREV_dmlc   = "09511cf9fe5ff103900a5eafb50870dc84cc17c8"
SRCREV_FORMAT = "rt_tvm_dlpack_dmlc"

S = "${UNPACKDIR}/tvmrt"

# Prebuilt aarch64 .so committed in-repo under obj/build_runtime/<soc>/lib.
# V2L shares the v2m runtime build (see apps/CMakeLists.txt LIBMERA_RT_PATH).
RUNTIME_LIBDIR = "obj/build_runtime/v2m/lib"

COMPATIBLE_MACHINE = "smarc-rzv2l"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    # Runtime shared libraries.
    install -d ${D}${libdir}
    install -m 0755 ${S}/${RUNTIME_LIBDIR}/libmera2_runtime.so ${D}${libdir}/
    install -m 0755 ${S}/${RUNTIME_LIBDIR}/libmera2_plan_io.so ${D}${libdir}/
    install -m 0755 ${S}/${RUNTIME_LIBDIR}/libdrp_tvm_rt.so    ${D}${libdir}/

    # TVM runtime headers to compile against the prebuilt runtime.
    install -d ${D}${includedir}
    cp -r ${S}/tvm/include/tvm                       ${D}${includedir}/
    cp -r ${S}/tvm/3rdparty/dlpack/include/dlpack    ${D}${includedir}/
    cp -r ${S}/tvm/3rdparty/dmlc-core/include/dmlc   ${D}${includedir}/
    install -m 0644 ${S}/tvm/3rdparty/compiler-rt/builtin_fp16.h ${D}${includedir}/

    # EdgeCortix-patched override headers replace the stock TVM runtime ones;
    # the prebuilt lib's ABI matches these, not stock (Dockerfile does the
    # same copy into tvm/include/tvm/runtime/).
    install -m 0644 ${S}/setup/include/*.h ${D}${includedir}/tvm/runtime/
}

# Prebuilt runtime libs use unversioned sonames (libfoo.so). Route them to the
# main package (the default sends unversioned .so to -dev) so -dev carries only
# headers and the libmmngr file-rdeps resolve against RDEPENDS:${PN}.
SOLIBS = ".so"
FILES_SOLIBSDEV = ""
FILES:${PN} = "${libdir}/lib*.so"

# Prebuilt aarch64 libs, not produced by this build — exempt from ldflags
# (no GNU_HASH / distro LDFLAGS) and text-relocation QA.
INSANE_SKIP:${PN} = "ldflags textrel"

# libdrp_tvm_rt links the mmngr userspace buffer libs (libmmngr/libmmngrbuf).
RDEPENDS:${PN} = "mmngr-user-module mmngrbuf-user-module"

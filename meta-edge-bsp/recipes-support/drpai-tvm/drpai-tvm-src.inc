# Shared pin for the Renesas DRP-AI TVM (RUHMI) upstream, consumed by every
# drpai-tvm-* recipe (runtime, app, runner). Bump the release in ONE place here.
#
# Release-2026-04-17 (DRP-AI TVM v2.7.0-hotfix2 / RUHMI R2026-04, mera2 2.5.1).
# The model-compile environment (rzv2l-drpai-compile-env) must pin this same
# release — the EdgeCortix runtime/compiler ABI is release-coupled; bump both.
#
# One git clone is shared across all consumers via DL_DIR (same URL + rev);
# each recipe composes this base into its own SRC_URI (the runtime names it
# ;name=rt for its multi-source fetch; app/runner use it directly).

DRPAI_TVM_GIT    ?= "git://github.com/renesas-rz/rzv_drp-ai_tvm.git;protocol=https;branch=main"
DRPAI_TVM_SRCREV ?= "110048ecadc6a997628d9a79024b9d59ae2ef7ea"

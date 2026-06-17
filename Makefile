.PHONY: help base dev bundle parse layers shell info clean-lock netboot-sync lock verify-pins purge

KAS ?= kas

# === Layer hosting (see docs/adr/0002-layer-hosting.md) ===
#
# KAS_REPO_REF_DIR points at a shared git-alternates cache. If a same-
# named clone exists under <ref-dir>/<repo>, kas pulls objects from it
# instead of re-downloading from upstream — near-instant repo setup,
# zero extra disk per project. SHA pins from kas/base.yml are still
# enforced; alternates only speed the fetch.
#
# Subdir is scoped per Yocto release line (`layers-wrynose/`) so a
# scarthgap or kirkstone project on the same host using
# `/mnt/yocto-nvme/layers-<release>/` doesn't cross-contaminate
# ref-counts or surface stale objects after an upstream force-push.
# Alternates are technically read-only and cross-release safe, but the
# mental-model isolation is cheap.
#
# If the dir doesn't exist, kas silently falls back to full clones —
# no error, no operator action needed for a first-time host.
#
# KAS_WORK_DIR relocates kas' clone target out of the repo root into
# .kas/, which is gitignored as a category. This means the repo root
# stays clean even on a host without a shared cache; you never get
# upstream layer directories polluting `ls`.
KAS_REPO_REF_DIR ?= /mnt/yocto-nvme/layers-wrynose
KAS_WORK_DIR     ?= $(CURDIR)/.kas
# Bitbake build dir at the traditional repo-root location. Without this
# kas would default KAS_BUILD_DIR to ${KAS_WORK_DIR}/build (= .kas/build),
# which works but doesn't match the universal Yocto convention every
# operator and doc references. .kas/ is for upstream layer clones only.
KAS_BUILD_DIR    ?= $(CURDIR)/build
export KAS_REPO_REF_DIR KAS_WORK_DIR KAS_BUILD_DIR

# === Stack composition ===
#
# The kas stack is image-agnostic: base + machine. The image is selected
# via the bitbake target (`bitbake edge-image-base|edge-image-dev`), not
# via a kas overlay. This follows the proven sibling-project pattern.
#
# If kas/local.yml exists (operator-private overlay for paths,
# parallelism, credentials), it is the entry point and already composes
# base + machine through its `includes:`. Otherwise we compose the
# tracked base + machine fragments directly.
BASE_DEFAULT = kas/base.yml:kas/machines/rzv2l.yml
ifneq ($(wildcard kas/local.yml),)
  BASE = kas/local.yml
else
  BASE = $(BASE_DEFAULT)
endif

# === Capability fragments (opt-in via make flags) ===
#
#   make dev TPM=1         # add meta-secure-core TPM2 + IMA/EVM stack
#   make dev VIRT=1        # add meta-virtualization (Podman/runc/crun)
#   make dev SBOM_TUNE=1   # add SBOM/CVE per-build tuning knobs
#
# Flags compose: `make dev TPM=1 VIRT=1` adds both. Each fragment is a
# pure additive overlay with no `includes:` — composition is explicit.
#
# Capability defaults (board-gated): the RZ/V2L SMARC EVK has no
# on-board TPM, so TPM2 is NOT default-on here. Boards with TPM
# hardware will include kas/tpm.yml from their machines/<board>.yml.
CAPABILITY_YMLS :=
ifeq ($(TPM),1)
  CAPABILITY_YMLS += kas/tpm.yml
endif
ifeq ($(VIRT),1)
  CAPABILITY_YMLS += kas/virtualization.yml
endif
ifeq ($(SBOM_TUNE),1)
  CAPABILITY_YMLS += kas/sbom-cve.yml
endif
ifeq ($(NETBOOT),1)
  CAPABILITY_YMLS += kas/dev-netboot.yml
endif

empty :=
space := $(empty) $(empty)
CAP_CHAIN := $(if $(CAPABILITY_YMLS),:$(subst $(space),:,$(CAPABILITY_YMLS)))

STACK = $(BASE)$(CAP_CHAIN)

# kas refuses to run if KAS_WORK_DIR is set to a non-existent dir
# (kas/context.py: os.path.abspath but no mkdir). Order-only prereq so
# every kas-invoking target finds .kas/ already created on a fresh tree.
$(KAS_WORK_DIR):
	@mkdir -p $@

help:
	@echo "edge-ai-yocto build system"
	@echo "=========================="
	@echo ""
	@echo "Image targets:"
	@echo "  make base                    Build edge-image-base (v0 wired tier)"
	@echo "  make dev                     Build edge-image-dev  (base + debug/profile/stress tools)"
	@echo "  make bundle                  Build edge-bundle (.raucb) for OTA install"
	@echo ""
	@echo "Capability flags (composable; combine freely):"
	@echo "  TPM=1                        + meta-secure-core (TPM2 + IMA/EVM userspace)"
	@echo "  VIRT=1                       + meta-virtualization (Podman/runc/crun)"
	@echo "  SBOM_TUNE=1                  + kas/sbom-cve.yml tuning knobs"
	@echo "  NETBOOT=1                    + U-Boot 'netboot' env macro (TFTP/NFS dev workflow)"
	@echo ""
	@echo "  Example: make dev NETBOOT=1"
	@echo "           sudo ./scripts/dev/sync-nfs-rootfs.sh   # after each rebuild"
	@echo "  See docs/dev/netboot-setup.md for host setup + per-board env."
	@echo ""
	@echo "Utility targets:"
	@echo "  make parse                   bitbake -p (parse-only sanity check)"
	@echo "  make layers                  bitbake-layers show-layers"
	@echo "  make shell                   Interactive KAS shell"
	@echo "  make info                    Show build configuration"
	@echo "  make lock                    Resolve floating branches to SHAs (writes kas/base.lock.yml)"
	@echo "  make verify-pins             Print every repo's HEAD; diff against base.yml/base.lock.yml"
	@echo "  make purge CONFIRM=1         Wipe .kas/ + build/ (repo tree only; KAS_REPO_REF_DIR untouched)"
	@echo "  make clean-lock              Remove stale build/bitbake.lock"
	@echo ""
	@echo "Standalone kas (outside make):"
	@echo "  . scripts/env.sh             Export KAS_WORK_DIR + KAS_REPO_REF_DIR into your shell"
	@echo "                               (required before 'kas shell …' to avoid in-tree clones)"
	@echo ""
	@echo "Composition: $(STACK)"
	@echo ""
	@echo "See AGENTS.md for the full orientation."

base: | $(KAS_WORK_DIR)
	@echo "==> Building edge-image-base [$(STACK)]"
	$(KAS) shell -c 'bitbake edge-image-base' $(STACK)

dev: | $(KAS_WORK_DIR)
	@echo "==> Building edge-image-dev [$(STACK)]"
	$(KAS) shell -c 'bitbake edge-image-dev' $(STACK)

# RAUC bundle. Signs with the chain at keys/dev/rauc/ (run
# scripts/rauc-init-certs.sh first if absent). Default BUNDLE_IMAGE_NAME
# is edge-image-base; override in kas/local.yml for dev OTA iteration:
#     BUNDLE_IMAGE_NAME = "edge-image-dev"
bundle: | $(KAS_WORK_DIR)
	@if [ ! -f keys/dev/rauc/rauc-signer.key ]; then \
		echo "RAUC signing keys missing at keys/dev/rauc/."; \
		echo "Run: ./scripts/rauc-init-certs.sh"; \
		exit 1; \
	fi
	@echo "==> Building edge-bundle [$(STACK)]"
	$(KAS) shell -c 'bitbake edge-bundle' $(STACK)
	@echo "==> Bundle artefacts:"
	@find build/tmp/deploy/images -name '*.raucb' -printf '    %p\n'

parse: | $(KAS_WORK_DIR)
	@echo "==> Parsing BitBake recipes [$(STACK)]"
	$(KAS) shell -c 'bitbake -p' $(STACK)

layers: | $(KAS_WORK_DIR)
	@echo "==> Showing layers [$(STACK)]"
	$(KAS) shell -c 'bitbake-layers show-layers' $(STACK)

shell: | $(KAS_WORK_DIR)
	@echo "==> Entering KAS shell [$(STACK)]"
	$(KAS) shell $(STACK)

info:
	@echo "edge-ai-yocto"
	@echo "============="
	@echo ""
	@echo "KAS:   $$($(KAS) --version 2>&1 | head -1)"
	@echo "Stack: $(STACK)"
	@echo ""
	@echo "Composition:"
	@echo "  base:         $(BASE)"
	@echo "  capabilities: $(if $(CAPABILITY_YMLS),$(CAPABILITY_YMLS),(none))"
	@echo ""

clean-lock:
	rm -f build/bitbake.lock

# Freeze floating upstream branches (e.g. meta-rauc on `wrynose`) to a
# concrete SHA. Writes kas/base.lock.yml next to kas/base.yml; commit
# the lock file so the build is bit-for-bit reproducible at this point
# in time. Re-run when you deliberately want to bump a floating branch.
lock: | $(KAS_WORK_DIR)
	@echo "==> Resolving floating branches to SHAs [$(STACK)]"
	$(KAS) lock $(STACK)

# Verify every cloned repo's HEAD matches what kas/base.yml (or the
# lock file) pinned. Run this as a sanity check before a release build:
#   make verify-pins | diff -u <(grep commit: kas/base.yml | awk '{print $$2}') -
verify-pins: | $(KAS_WORK_DIR)
	@echo "==> Reporting HEAD per repo [$(STACK)]"
	$(KAS) for-all-repos $(STACK) 'echo "$$(basename $$(pwd)): $$(git rev-parse HEAD)"'

# Wipe kas-managed workspace state IN THE REPO TREE ONLY:
#   $(KAS_WORK_DIR)/  — kas-managed clones + the bitbake build dir under it
#   $(CURDIR)/build/  — pre-restructure orphan build dir (no-op if absent)
#
# Deliberately does NOT use `kas purge $(STACK)` — on kas 4.8.2 that also
# wipes $(KAS_REPO_REF_DIR), which is fleet-shared cache. The scoped rm
# below is repo-tree only.
#
# Does NOT touch kas/local.yml, downloads/, sstate-cache/, or
# $(KAS_REPO_REF_DIR). For a scorched-earth pass, blow those away
# manually with the caveat that downloads/ + sstate-cache/ may be shared.
#
# Guarded with CONFIRM=1 so a tab-complete can't fire it accidentally.
purge:
	@if [ -z "$(CONFIRM)" ]; then \
		echo "Refusing: 'make purge' is destructive. Re-run with CONFIRM=1."; \
		echo "  Will remove: $(KAS_WORK_DIR)/  $(CURDIR)/build/"; \
		echo "  Will NOT touch: KAS_REPO_REF_DIR ($(KAS_REPO_REF_DIR))"; \
		exit 1; \
	fi
	@echo "==> Purging kas-managed state in repo tree only"
	@echo "    Removing $(KAS_WORK_DIR)/ and $(CURDIR)/build/"
	@echo "    KAS_REPO_REF_DIR ($(KAS_REPO_REF_DIR)) is NOT touched."
	rm -rf $(KAS_WORK_DIR) $(CURDIR)/build

# Push the freshly-built rootfs + fitImage to the host's NFS export and
# TFTP dir so the next `run netboot` on the board picks them up. Requires
# root for tar to preserve uid/gid/xattrs into the NFS root. Does NOT
# rebuild — chain it with `make dev NETBOOT=1` if you want a fresh build:
#   make dev NETBOOT=1 && sudo ./scripts/dev/sync-nfs-rootfs.sh
# See docs/dev/netboot-setup.md for one-time host + board setup.
netboot-sync:
	@echo "==> Syncing latest rootfs + fitImage to NFS/TFTP"
	sudo ./scripts/dev/sync-nfs-rootfs.sh

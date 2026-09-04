.PHONY: help base dev prod bundle parse layers shell info clean-lock netboot-sync lock verify-pins purge hooks

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
#   make dev AI=1          # add the DRP-AI inference stack (RZ/V2L)
#   make dev SBOM_TUNE=1   # add SBOM/CVE per-build tuning knobs
#   make dev JTAG=1        # KASLR off + kgdb + debug-safe (JTAG kernel labs)
#   make dev BPF=1         # kernel BTF + bpftool (libbpf CO-RE labs; size-heavy)
#   make dev OPTEE_EXAMPLES=1    # add the OP-TEE demo TAs (bring-up only)
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
ifeq ($(AI),1)
  CAPABILITY_YMLS += kas/ai-drpai.yml
endif
ifeq ($(SBOM_TUNE),1)
  CAPABILITY_YMLS += kas/sbom-cve.yml
endif
ifeq ($(NETBOOT),1)
  CAPABILITY_YMLS += kas/dev-netboot.yml
endif
ifeq ($(JTAG),1)
  CAPABILITY_YMLS += kas/jtag-debug.yml
endif
ifeq ($(BPF),1)
  CAPABILITY_YMLS += kas/bpf-labs.yml
endif
ifeq ($(OPTEE_EXAMPLES),1)
  CAPABILITY_YMLS += kas/optee-examples.yml
endif

empty :=
space := $(empty) $(empty)
CAP_CHAIN := $(if $(CAPABILITY_YMLS),:$(subst $(space),:,$(CAPABILITY_YMLS)))

STACK = $(BASE)$(CAP_CHAIN)

# === Boot target (on-disk layout) ===
#
#   make dev EDGE_BOOT_TARGET=emmc   # GPT user area + systemd-repart (eMMC boot)
#
# Unset → recipe default "esd" (MBR, eSD boot — unchanged behaviour). Passed
# as a bitbake env var, not a kas layer; the recipe selects the matching
# WKS_FILE and growth mechanism.
BOOT_TARGET_ENV := $(if $(EDGE_BOOT_TARGET),EDGE_BOOT_TARGET=$(EDGE_BOOT_TARGET) ,)

# === Build tier (EDGE_PROFILE) ===
#
# Tier is resolved at INVOCATION, not pinned in an image recipe (an image
# recipe parses after the distro conf's `require edge-profile-${EDGE_PROFILE}`
# already ran). EDGE_PROFILE must be whitelisted in BB_ENV_PASSTHROUGH_ADDITIONS
# *in the shell env* — bitbake filters the inherited environment at startup,
# before any conf is parsed, so the `.=` in edge-features.inc is too late to
# rescue the startup import. Set both on the bitbake command line together.
# $(1) = profile (dev|prod), $(2) = image target.
define edge_build
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS EDGE_PROFILE EDGE_OTA_BACKEND EDGE_BOOT_TARGET EDGE_KERNEL_DEV_FRAGMENTS" EDGE_PROFILE=$(1) $(BOOT_TARGET_ENV)bitbake $(2)' $(STACK)
endef

# EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION defaults to "1" (edge-features.inc), so
# every image now pulls in ota-certs' encrypted-bundle key install, which
# bbfatals deep inside do_install if keys/dev/rauc/ has no recipient key yet
# (scripts/rauc-init-certs.sh not run). Advisory, not a gate: it greps the
# composed $(STACK) files for an explicit override to "0" and stays silent
# if it finds one — cheap, and covers the common case (kas/local.yml, a
# capability fragment) without paying kas/bitbake's own startup cost. It
# cannot see a shell-env override (BB_ENV_PASSTHROUGH_ADDITIONS), so it can
# still misfire there; that is a known gap, not a claim of certainty. Its
# job is only to turn a bbfatal several minutes into a cold build into a
# one-line heads-up before kas even starts.
define check_rauc_keys
	@if [ ! -f keys/dev/rauc/rauc-recipient.key ] \
	   && ! grep -lqE '^[[:space:]]*EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION[[:space:]]*=[[:space:]]*"0"' $(subst :, ,$(STACK)) 2>/dev/null; then \
		echo "note: keys/dev/rauc/rauc-recipient.key not found."; \
		echo "      Bundle encryption defaults on (EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION) and no"; \
		echo "      composed kas file overrides it off, so this build will most likely fail"; \
		echo "      at ota-certs' do_install. (A shell-env override is not checked here.)"; \
		echo "      Run: ./scripts/rauc-init-certs.sh"; \
	fi
endef

# kas refuses to run if KAS_WORK_DIR is set to a non-existent dir
# (kas/context.py: os.path.abspath but no mkdir). Order-only prereq so
# every kas-invoking target finds .kas/ already created on a fresh tree.
$(KAS_WORK_DIR):
	@mkdir -p $@

help:
	@echo "edge-ai-yocto build system"
	@echo "=========================="
	@echo ""
	@echo "Image targets (tier = EDGE_PROFILE, set per target):"
	@echo "  make base                    Build edge-image-base (dev tier; v0 wired baseline)"
	@echo "  make dev                     Build edge-image-dev  (dev tier; + debug/profile/stress tools)"
	@echo "  make prod                    Build edge-image-prod (prod tier; hardened, no package-mgmt)"
	@echo "  make bundle                  Build edge-bundle (.raucb) for OTA install (dev tier)"
	@echo "  make bundle EDGE_PROFILE=prod  Bundle a prod image (set BUNDLE_IMAGE_NAME=edge-image-prod)"
	@echo ""
	@echo "Capability flags (composable; combine freely):"
	@echo "  TPM=1                        + meta-secure-core (TPM2 + IMA/EVM userspace)"
	@echo "  VIRT=1                       + meta-virtualization (Podman/runc/crun)"
	@echo "  AI=1                         + DRP-AI inference stack (RZ/V2L; pair with VIRT=1)"
	@echo "  SBOM_TUNE=1                  + kas/sbom-cve.yml tuning knobs"
	@echo "  NETBOOT=1                    + U-Boot 'netboot' env macro (TFTP/NFS dev workflow)"
	@echo "  JTAG=1                       + KASLR off, kgdb, debug-safe boot (JTAG kernel labs)"
	@echo "  BPF=1                        + kernel BTF + bpftool (libbpf CO-RE labs; size-heavy)"
	@echo "  OPTEE_EXAMPLES=1             + OP-TEE demo TAs (bring-up/debug; off in shipped images)"
	@echo "  EDGE_BOOT_TARGET=emmc        GPT user area + systemd-repart (eMMC boot; default esd)"
	@echo ""
	@echo "  Example: make dev NETBOOT=1"
	@echo "           sudo ./scripts/dev/sync-nfs-rootfs.sh   # after each rebuild"
	@echo "  See docs/dev/netboot-setup.md for host setup + per-board env."
	@echo ""
	@echo "Utility targets:"
	@echo "  make hooks                   Install the git hooks (run once per clone)"
	@echo "  make parse                   bitbake -p (parse-only sanity check)"
	@echo "  make layers                  bitbake-layers show-layers"
	@echo "  make shell                   Interactive KAS shell"
	@echo "  make info                    Show build configuration"
	@echo "  make lock                    Resolve floating branches to SHAs (writes kas/base.lock.yml)"
	@echo "  make verify-pins             Print every repo's HEAD; diff against base.yml/base.lock.yml"
	@echo "  make purge CONFIRM=1         Wipe .kas/ + build/ (repo tree only; KAS_REPO_REF_DIR untouched)"
	@echo "  make clean-lock              Remove build/bitbake.lock if unheld"
	@echo ""
	@echo "Standalone kas (outside make):"
	@echo "  . scripts/env.sh             Export KAS_WORK_DIR + KAS_REPO_REF_DIR into your shell"
	@echo "                               (required before 'kas shell …' to avoid in-tree clones)"
	@echo ""
	@echo "Composition: $(STACK)"
	@echo ""
	@echo "See AGENTS.md for the full orientation."

base: | $(KAS_WORK_DIR)
	$(call check_rauc_keys)
	@echo "==> Building edge-image-base (dev tier) [$(STACK)]"
	$(call edge_build,dev,edge-image-base)

dev: | $(KAS_WORK_DIR)
	$(call check_rauc_keys)
	@echo "==> Building edge-image-dev [$(STACK)]"
	$(call edge_build,dev,edge-image-dev)

prod: | $(KAS_WORK_DIR)
	$(call check_rauc_keys)
	@echo "==> Building edge-image-prod [$(STACK)]"
	$(call edge_build,prod,edge-image-prod)

# RAUC bundle. Signs with the chain at keys/dev/rauc/ (run
# scripts/rauc-init-certs.sh first if absent). BUNDLE_IMAGE_NAME selects the
# image to bundle (default edge-image-dev; set in kas/local.yml). EDGE_PROFILE
# must match that image's tier — defaults to dev; for a prod bundle:
#     make bundle EDGE_PROFILE=prod        # with BUNDLE_IMAGE_NAME=edge-image-prod
# EDGE_BOOT_TARGET must match the booted board: an emmc board needs
#     make bundle EDGE_BOOT_TARGET=emmc    # else the slot rootfs ships the
# esd grow path, which fails on the GPT layout.
EDGE_PROFILE ?= dev
bundle: | $(KAS_WORK_DIR)
	@if [ ! -f keys/dev/rauc/rauc-signer.key ]; then \
		echo "RAUC signing keys missing at keys/dev/rauc/."; \
		echo "Run: ./scripts/rauc-init-certs.sh"; \
		exit 1; \
	fi
	$(call check_rauc_keys)
	@echo "==> Building edge-bundle (EDGE_PROFILE=$(EDGE_PROFILE)) [$(STACK)]"
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS EDGE_PROFILE EDGE_OTA_BACKEND BUNDLE_IMAGE_NAME EDGE_BOOT_TARGET EDGE_KERNEL_DEV_FRAGMENTS" EDGE_PROFILE=$(EDGE_PROFILE) $(BOOT_TARGET_ENV)bitbake edge-bundle' $(STACK)
	@echo "==> Bundle artefacts:"
	@find build/tmp/deploy/images -name '*.raucb' -printf '    %p\n'

parse: | $(KAS_WORK_DIR)
	@echo "==> Parsing BitBake recipes (EDGE_PROFILE=$(EDGE_PROFILE)) [$(STACK)]"
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS EDGE_PROFILE EDGE_OTA_BACKEND EDGE_BOOT_TARGET EDGE_KERNEL_DEV_FRAGMENTS" EDGE_PROFILE=$(EDGE_PROFILE) $(BOOT_TARGET_ENV)bitbake -p' $(STACK)

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

# bitbake decides whether to start a cooker or attach to a running one purely by
# whether it can acquire build/bitbake.lock (bitbake/lib/bb/main.py, "Starting
# bitbake server" vs "Reconnecting"). Removing the file while a server holds it
# leaves that flock on the unlinked inode, so the next invocation creates a new
# lock, takes it, and starts a SECOND server against the same TMPDIR. Only a
# lock nothing holds is stale. bitbake writes the server pid into the file.
clean-lock:
	@if [ ! -e build/bitbake.lock ]; then \
	    echo "no build/bitbake.lock — nothing to clean"; \
	elif flock -n build/bitbake.lock true 2>/dev/null; then \
	    rm -f build/bitbake.lock; \
	    echo "removed stale build/bitbake.lock"; \
	else \
	    holder=$$(cat build/bitbake.lock 2>/dev/null | tr -d '\n'); \
	    echo "build/bitbake.lock is held by $${holder:-another process (pid not recorded)}"; \
	    echo "A bitbake server is live; removing the lock would make the next"; \
	    echo "bitbake start a second server on this build directory."; \
	    echo "Shut it down instead:  make shell  then  bitbake -m"; \
	    exit 1; \
	fi
	@if [ -S build/bitbake.sock ] && [ ! -e build/bitbake.lock ]; then \
	    echo "warning: build/bitbake.sock exists with no lock file; a server may"; \
	    echo "         still be running unlocked (pgrep -f bitbake-server)"; \
	fi

# pre-commit installs into .git/hooks, which is per-clone and untracked —
# a fresh clone has both gates silently disabled until this runs. Both
# stages are needed: --hook-type commit-msg alone leaves the key guard off,
# and a bare `pre-commit install` leaves the subject check off. Idempotent.
hooks:
	@command -v pre-commit >/dev/null || { \
	  echo "pre-commit not on PATH — install it first: pipx install pre-commit"; exit 1; }
	@pre-commit install --hook-type pre-commit --hook-type commit-msg

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

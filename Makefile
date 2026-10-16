.PHONY: help base dev prod bundle bootchain-bundle bootloader-package parse layers shell info clean-lock netboot-sync lock verify-pins purge hooks ci kernel-config-export kernel-hardening-check cve

KAS ?= kas

# Layer clones live in .kas/; KAS_REPO_REF_DIR is a git-alternates cache that
# only speeds the fetch (absent = full clones). See docs/dev/build-system.md.
KAS_REPO_REF_DIR ?= /mnt/yocto-nvme/layers-wrynose
KAS_WORK_DIR     ?= $(CURDIR)/.kas
export KAS_REPO_REF_DIR KAS_WORK_DIR

# BOARD selects kas/machines/<board>.yml, which sets MACHINE.
BOARD ?= rzv2l
ifeq ($(wildcard kas/machines/$(BOARD).yml),)
  $(error BOARD=$(BOARD) is unknown; kas/machines/$(BOARD).yml does not exist. \
Available: $(patsubst kas/machines/%.yml,%,$(wildcard kas/machines/*.yml)))
endif
BASE = kas/base.yml:kas/machines/$(BOARD).yml$(if $(wildcard kas/local.yml),:kas/local.yml,)

# One tree per board; override: an inherited KAS_BUILD_DIR must never pick it.
override KAS_BUILD_DIR := $(CURDIR)/build/$(BOARD)
export KAS_BUILD_DIR

# Capability flags: FLAG=1 composes kas/<fragment>.yml; `make help` lists them.
FLAGS := TPM:tpm SBOM_TUNE:sbom-cve NETBOOT:dev-netboot JTAG:jtag-debug BPF:bpf-labs \
         OPTEE_EXAMPLES:optee-examples BOOTLOADER_UPDATE:bootloader-update
flag_var  = $(word 1,$(subst :, ,$(1)))
flag_yml  = kas/$(word 2,$(subst :, ,$(1))).yml
CAPABILITY_YMLS := $(strip $(foreach f,$(FLAGS),$(if $(filter 1,$($(call flag_var,$(f)))),$(call flag_yml,$(f)))))

# ACCEL=<name> adds kas/accel/<name>.yml on top of the machine's own accelerator.
ifneq ($(filter-out none,$(ACCEL)),)
  ifeq ($(wildcard kas/accel/$(ACCEL).yml),)
    $(error ACCEL=$(ACCEL) is unknown. Available: none $(patsubst kas/accel/%.yml,%,$(wildcard kas/accel/*.yml)))
  endif
  CAPABILITY_YMLS += kas/accel/$(ACCEL).yml
endif
ifeq ($(BOOTLOADER_UPDATE),1)
  ifeq ($(filter $(BOARD),rzv2l raspberrypi5),)
    $(warning note: BOOTLOADER_UPDATE=1 has no backend for BOARD=$(BOARD); it is a no-op here)
  endif
endif

# On-disk layout. esd is the default; any other is kas/boot/<layout>.yml. The
# layout last selected by a build target is stamped in the build dir and
# reused when LAYOUT is not given; build targets refuse a different LAYOUT unless LAYOUT_CHANGE=1. parse
# ignores the stamp, so parse-only checks stay independent of the tree.
ifdef EDGE_BOOT_TARGET
  $(error EDGE_BOOT_TARGET is replaced by LAYOUT=<esd|emmc>)
endif
LAYOUT       :=
LAYOUT_STAMP := $(KAS_BUILD_DIR)/edge-layout
BUILT_LAYOUT := $(strip $(shell cat $(LAYOUT_STAMP) 2>/dev/null))
LAYOUT_EFF    = $(or $(LAYOUT),$(BUILT_LAYOUT),esd)
parse: LAYOUT_EFF = $(or $(LAYOUT),esd)
ifneq ($(filter-out esd,$(LAYOUT)),)
  ifeq ($(wildcard kas/boot/$(LAYOUT).yml),)
    $(error LAYOUT=$(LAYOUT) is unknown. Available: esd $(patsubst kas/boot/%.yml,%,$(wildcard kas/boot/*.yml)))
  endif
endif
layout_yml = $(if $(filter-out esd,$(LAYOUT_EFF)),:kas/boot/$(LAYOUT_EFF).yml)

empty :=
space := $(empty) $(empty)
STACK = $(BASE)$(if $(strip $(CAPABILITY_YMLS)),:$(subst $(space),:,$(strip $(CAPABILITY_YMLS))))$(layout_yml)

# Build settings reach bitbake through kas/base.yml env:, set per command below.
# := and unexport keep a value from the shell environment out of the build.
EDGE_PROFILE := dev
IMAGE        := dev
unexport EDGE_PROFILE BUNDLE_IMAGE_NAME EDGE_BUNDLE_SBOM_CVE

# $(1) = build settings for kas env:, $(2) = command run in the kas shell.
kas_run = $(1) $(KAS) shell -c '$(2)' $(STACK)

define layout_guard
	@if [ -n "$(LAYOUT)" ] && [ -n "$(BUILT_LAYOUT)" ] && [ "$(LAYOUT)" != "$(BUILT_LAYOUT)" ] \
	    && [ "$(LAYOUT_CHANGE)" != 1 ]; then \
		echo "$(KAS_BUILD_DIR) is built for LAYOUT=$(BUILT_LAYOUT); add LAYOUT_CHANGE=1 to build LAYOUT=$(LAYOUT)"; \
		exit 1; \
	fi
	@echo $(LAYOUT_EFF) > $(LAYOUT_STAMP)
endef

# ota-certs fails at do_install without the bundle-encryption recipient key,
# unless a composed kas file turns encryption off.
define check_rauc_keys
	@if [ ! -f keys/dev/rauc/rauc-recipient.key ] \
	   && ! grep -lqE '^[[:space:]]*EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION[[:space:]]*=[[:space:]]*"0"' $(subst :, ,$(STACK)) 2>/dev/null; then \
		echo "note: keys/dev/rauc/rauc-recipient.key is missing and bundle encryption is on;"; \
		echo "      ota-certs will fail. Run: ./scripts/rauc-init-certs.sh"; \
	fi
endef

define require_rauc_signer
	@test -f keys/dev/rauc/rauc-signer.key || { \
		echo "RAUC signing keys missing at keys/dev/rauc/. Run: ./scripts/rauc-init-certs.sh"; exit 1; }
endef

# Kernel module signing dev key, generated once; every kernel build signs with it.
define require_module_key
	@test -f keys/dev/kernel/module-signing.pem || ./scripts/kernel-module-key-init.sh
endef

define require_rzv2l
	@test "$(BOARD)" = rzv2l || { echo "$@: RZ/V2L only (BOARD=rzv2l)"; exit 1; }
endef

# kas refuses a KAS_WORK_DIR or KAS_BUILD_DIR that does not exist.
KAS_DIRS := $(KAS_WORK_DIR) $(KAS_BUILD_DIR)
$(KAS_DIRS):
	@mkdir -p $@

help: ## this list
	@echo "Targets:"
	@awk -F ':.*## ' '/^[a-z-]+:.*## /{ printf "  make %-24s %s\n", $$1, $$2 }' $(firstword $(MAKEFILE_LIST))
	@echo ""
	@echo "Capability flags (compose freely):"
	@$(foreach f,$(FLAGS),printf '  %-29s %s\n' "$(call flag_var,$(f))=1" \
	    "$$(sed -nE '1{s/^# *[A-Za-z ]*fragment: *//;s/\.$$//;p}' $(call flag_yml,$(f)))";)
	@echo ""
	@echo "Settings:"
	@echo "  BOARD=<name>                  $(patsubst kas/machines/%.yml,%,$(wildcard kas/machines/*.yml)) (default rzv2l)"
	@echo "  ACCEL=<name>                  add kas/accel/<name>.yml over the machine's accelerator"
	@echo "  LAYOUT=esd|emmc               on-disk layout, remembered per build dir (LAYOUT_CHANGE=1 to switch)"
	@echo "  IMAGE=dev|prod                image and tier a bundle carries (default dev)"
	@echo "  SBOM_CVE=1                    image SBOM + CVE report in a dev bundle (always on for prod)"
	@echo "  EDGE_PROFILE=dev|prod         tier for parse, shell, layers"
	@echo ""
	@echo "Composition: $(STACK)"

base: | $(KAS_DIRS) ## edge-image-base (dev tier)
	$(layout_guard)
	$(require_module_key)
	$(check_rauc_keys)
	$(call kas_run,EDGE_PROFILE=dev,bitbake edge-image-base)

dev: | $(KAS_DIRS) ## edge-image-dev (dev tier; debug, profiling and stress tools)
	$(layout_guard)
	$(require_module_key)
	$(check_rauc_keys)
	$(call kas_run,EDGE_PROFILE=dev,bitbake edge-image-dev)

prod: | $(KAS_DIRS) ## edge-image-prod (prod tier; hardened, no package management)
	$(layout_guard)
	$(require_module_key)
	$(check_rauc_keys)
	$(call kas_run,EDGE_PROFILE=prod,bitbake edge-image-prod)

bundle: | $(KAS_DIRS) ## edge-bundle (.raucb) for OTA; builds the image too
	@test "$(origin EDGE_PROFILE)" != "command line" -a "$(origin BUNDLE_IMAGE_NAME)" != "command line" || { \
		echo "bundle: IMAGE=dev|prod selects tier and image together; drop EDGE_PROFILE/BUNDLE_IMAGE_NAME"; exit 1; }
	@case "$(IMAGE)" in dev|prod) ;; *) echo "IMAGE=$(IMAGE): expected dev or prod"; exit 1;; esac
	$(layout_guard)
	$(require_rauc_signer)
	$(require_module_key)
	$(check_rauc_keys)
	$(call kas_run,EDGE_PROFILE=$(IMAGE) BUNDLE_IMAGE_NAME=edge-image-$(IMAGE)$(if $(filter 1,$(SBOM_CVE)), EDGE_BUNDLE_SBOM_CVE=1),bitbake edge-bundle)
	@find $(KAS_BUILD_DIR)/tmp/deploy/images -name '*.raucb' -printf '    %p\n'

bootchain-bundle: | $(KAS_DIRS) ## RZ/V2L bootloader-only bundle for the eMMC boot-emmc slot (LAYOUT=emmc)
	$(require_rzv2l)
	@test "$(LAYOUT_EFF)" = emmc || { echo "bootchain-bundle: needs LAYOUT=emmc (tree is $(LAYOUT_EFF))"; exit 1; }
	$(layout_guard)
	$(require_rauc_signer)
	$(require_module_key)
	$(check_rauc_keys)
	$(call kas_run,EDGE_PROFILE=$(EDGE_PROFILE),bitbake rzv2l-bootchain-bundle)
	@find $(KAS_BUILD_DIR)/tmp/deploy/images -name 'rzv2l-bootchain-bundle*.raucb' -printf '    %p\n'

bootloader-package: | $(KAS_DIRS) ## RZ/V2L host package: BL2/FIP + manifest + updater, out of band
	$(require_rzv2l)
	$(layout_guard)
	$(call kas_run,EDGE_PROFILE=$(EDGE_PROFILE),bitbake rzv2l-bootloader-update -c deploy)
	@find $(KAS_BUILD_DIR)/tmp/deploy/images -name 'rzv2l-bootloader-*.tar.gz' -printf '    %p\n'

parse: | $(KAS_DIRS) ## bitbake -p (parse-only check; EDGE_PROFILE=, LAYOUT= apply)
	$(call kas_run,EDGE_PROFILE=$(EDGE_PROFILE),bitbake -p)

ci: ## parse-check origin/main in a worktree, post commit statuses (CI_ARGS=…, docs/dev/ci.md)
	scripts/ci/local-check.sh $(CI_ARGS)

KHC_PROFILE ?= prod
KHC_OUT     ?= $(CURDIR)/build/khc/$(BOARD)-$(KHC_PROFILE).config
KHC_DIR      = meta-edge-bsp/recipes-kernel/linux/files/khc

kernel-config-export: | $(KAS_DIRS) ## expanded kernel .config (configure only) -> build/khc/<board>-prod.config
	$(require_module_key)
	$(call kas_run,EDGE_PROFILE=$(KHC_PROFILE),$(CURDIR)/scripts/ci/kernel-config-export.sh $(KHC_OUT))

kernel-hardening-check: kernel-config-export ## KSPP gate on the exported .config
	$(KHC_DIR)/khc-gate.py --config $(KHC_OUT) --baseline $(KHC_DIR)/$(BOARD)-$(KHC_PROFILE).baseline.json \
	    --report $(CURDIR)/build/khc/$(BOARD)-$(KHC_PROFILE)-report.md

cve: ## host CVE monitor, no kas: make cve ARGS='<subcommand> …' (scripts/cve-monitor.py)
	@test -n "$(ARGS)" || { python3 scripts/cve-monitor.py --help; exit 2; }
	python3 scripts/cve-monitor.py $(ARGS)

layers: | $(KAS_DIRS) ## bitbake-layers show-layers
	$(call kas_run,EDGE_PROFILE=$(EDGE_PROFILE),bitbake-layers show-layers)

shell: | $(KAS_DIRS) ## interactive kas shell (EDGE_PROFILE= applies)
	EDGE_PROFILE=$(EDGE_PROFILE) $(KAS) shell $(STACK)

info: ## build configuration
	@echo "kas:    $$($(KAS) --version 2>&1 | head -1)"
	@echo "board:  $(BOARD)   build dir: $(KAS_BUILD_DIR)"
	@echo "layout: $(LAYOUT_EFF) (built: $(or $(BUILT_LAYOUT),none))"
	@echo "stack:  $(STACK)"

lock: | $(KAS_DIRS) ## resolve floating branches to SHAs (writes kas/base.lock.yml)
	$(KAS) lock $(STACK)

verify-pins: | $(KAS_DIRS) ## checked-out HEAD of every composed repo (a kas-patched repo shows the patched commit)
	$(KAS) for-all-repos $(STACK) 'echo "$$(basename $$(pwd)): $$(git rev-parse HEAD)"'

# A held bitbake.lock means a live server; removing it starts a second server
# on the same TMPDIR. Only an unheld lock is removed.
clean-lock: ## remove the build dir's bitbake.lock if no server holds it
	@if [ ! -e $(KAS_BUILD_DIR)/bitbake.lock ]; then \
	    echo "no $(KAS_BUILD_DIR)/bitbake.lock — nothing to clean"; \
	elif flock -n $(KAS_BUILD_DIR)/bitbake.lock true 2>/dev/null; then \
	    rm -f $(KAS_BUILD_DIR)/bitbake.lock; echo "removed stale $(KAS_BUILD_DIR)/bitbake.lock"; \
	else \
	    echo "$(KAS_BUILD_DIR)/bitbake.lock is held by $$(tr -d '\n' < $(KAS_BUILD_DIR)/bitbake.lock)"; \
	    echo "Shut the server down instead: make shell, then bitbake -m"; exit 1; \
	fi

hooks: ## install the commit and commit-msg git hooks (once per clone)
	@command -v pre-commit >/dev/null || { echo "pre-commit not on PATH: pipx install pre-commit"; exit 1; }
	@pre-commit install --hook-type pre-commit --hook-type commit-msg

# Not `kas purge`: on kas 4.8.2 that also wipes KAS_REPO_REF_DIR, a shared cache.
purge: ## wipe .kas/ and build/ (every board's TMPDIR); CONFIRM=1 required
	@test "$(CONFIRM)" = 1 || { echo "Refusing: removes $(KAS_WORK_DIR)/ and $(CURDIR)/build/. Re-run with CONFIRM=1."; exit 1; }
	rm -rf $(KAS_WORK_DIR) $(CURDIR)/build

netboot-sync: ## copy the last rootfs + fitImage to the NFS/TFTP export (docs/dev/netboot/)
	sudo ./scripts/dev/sync-nfs-rootfs.sh

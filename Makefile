# Edge Appliance Build System
# Builds immutable Kairos-based OS images with NVIDIA DOCA for AI-RA-Infra profile
#
# Layout:
#   src/       — Our modified files (Dockerfile, Earthfile, overlays), applied into CanvOS/
#   redist/    — Local firmware downloads (.deb, .bfb), copied into CanvOS/ at build time
#   CanvOS/    — Upstream clone, never committed to directly
#
# Usage:
#   make download           # Download firmware to redist/
#   make build              # Build from local redist/ files
#   make build-url          # Build from URLs (no local firmware needed)
#   make test               # Verify built image + ISO
#   make clean              # Remove build artifacts + redist/ + revert CanvOS/
#   make info               # Show current configuration

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Paths
SRC_DIR    := $(CURDIR)/src
REDIST_DIR := $(CURDIR)/redist
CANVOS_DIR := $(CURDIR)/CanvOS
BUILD_DIR  := $(CURDIR)/build
ARG_FILE   := $(CANVOS_DIR)/.arg

# Build configuration — override via environment or make arguments
# e.g., make build K8S_VERSION=1.34.2 IMAGE_REGISTRY=myregistry.io
CUSTOM_TAG        ?= demo
IMAGE_REGISTRY    ?= ttl.sh
OS_DISTRIBUTION   ?= ubuntu
IMAGE_REPO        ?= $(OS_DISTRIBUTION)
OS_VERSION        ?= 24.04
K8S_DISTRIBUTION  ?= kubeadm
K8S_VERSION       ?= 1.34.2
ARCH              ?= amd64
ISO_NAME          ?= palette-edge-installer
UPDATE_KERNEL     ?= false

# Edge Appliance settings
EDGE_APPLIANCE    ?= true
DOCA_VERSION      ?= 3.3.0

# Firmware file names (used for local redist/ builds)
BFB_NAME          := bf-bundle-3.2.1-34_25.11_ubuntu-24.04_64k_prod.bfb

# Firmware download URLs
BFB_URL           := https://content.mellanox.com/BlueField/BFBs/Ubuntu24.04/$(BFB_NAME)

# BFB_FILE controls what the build uses:
#   - Default: local filename (from redist/)
#   - Override with URL: make build-url
BFB_FILE          ?= $(BFB_NAME)

# Derived values (must match PE_VERSION in src/Earthfile)
PE_VERSION        := $(shell grep -m1 '^ARG PE_VERSION=' $(SRC_DIR)/Earthfile 2>/dev/null | cut -d= -f2 || echo "unknown")
PROVIDER_IMAGE    := $(IMAGE_REGISTRY)/$(IMAGE_REPO):$(K8S_DISTRIBUTION)-$(K8S_VERSION)-$(PE_VERSION)-$(CUSTOM_TAG)
INSTALLER_IMAGE   := palette-installer-image:$(PE_VERSION)-$(CUSTOM_TAG)

# Minimum free disk space in GB
MIN_DISK_GB       := 30

# Files we overlay from src/ into CanvOS/
OVERLAY_FILES := \
	Dockerfile \
	Earthfile \
	.arg.template \
	overlay/files/opt/spectrocloud/nodeprep.sh \
	overlay/files/etc/modprobe.d/blacklist-nouveau.conf \
	overlay/files/etc/modprobe.d/ib_core.conf \
	overlay/files/etc/lldpd.d/rcp-lldpd.conf \
	overlay/files/etc/modules-load.d/nfsrdma.conf \
	hack/launch-qemu.sh \
	hack/smoke-test-auto.sh

##@ Help
.PHONY: help
help: ## Show this help message
	@echo "Edge Appliance Build System — AI-RA-Infra Profile"
	@echo ""
	@echo "Provider image:  $(PROVIDER_IMAGE)"
	@echo "Installer ISO:   $(BUILD_DIR)/$(ISO_NAME).iso"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Setup & Configuration
.PHONY: setup
setup: ## Apply src/ files into CanvOS/ (resets CanvOS/ first)
	@echo "=== Resetting CanvOS/ to upstream ==="
	@cd $(CANVOS_DIR) && git restore Dockerfile Earthfile .arg.template .gitignore 2>/dev/null || true
	@rm -f $(CANVOS_DIR)/overlay/files/opt/spectrocloud/nodeprep.sh
	@rm -f $(CANVOS_DIR)/overlay/files/etc/modprobe.d/blacklist-nouveau.conf
	@rm -f $(CANVOS_DIR)/overlay/files/etc/modprobe.d/ib_core.conf
	@rm -f $(CANVOS_DIR)/overlay/files/etc/lldpd.d/rcp-lldpd.conf
	@rm -f $(CANVOS_DIR)/overlay/files/etc/modules-load.d/nfsrdma.conf
	@rm -f $(CANVOS_DIR)/EDGE-APPLIANCE-BUILD.md $(CANVOS_DIR)/CLAUDE.md
	@echo "=== Applying src/ to CanvOS/ ==="
	@for f in $(OVERLAY_FILES); do \
		if [ ! -f "$(SRC_DIR)/$$f" ]; then \
			echo "  [ERROR] Missing: src/$$f"; \
			exit 1; \
		fi; \
		mkdir -p "$(CANVOS_DIR)/$$(dirname $$f)"; \
		cp "$(SRC_DIR)/$$f" "$(CANVOS_DIR)/$$f"; \
		echo "  [OK] src/$$f"; \
	done
	@touch "$(CANVOS_DIR)/.empty-placeholder"
	@echo ""
	@echo "Applied $(words $(OVERLAY_FILES)) files to CanvOS/"

.PHONY: setup-firmware
setup-firmware: ## Copy redist/ firmware into CanvOS/ (skipped for URLs or non-Edge builds)
	@echo "=== Staging firmware into CanvOS/ ==="
	@if [ "$(EDGE_APPLIANCE)" != "true" ]; then \
		echo "  [SKIP] EDGE_APPLIANCE is not true — no firmware needed"; \
	else \
		echo "  [INFO] DOCA $(DOCA_VERSION) — installed from NVIDIA apt repo during build"; \
		echo "  [INFO] nvidia-open — installed from CUDA apt repo during build"; \
		case "$(BFB_FILE)" in \
			http://*|https://*) echo "  [SKIP] BFB — URL, downloaded during build" ;; \
			*) \
				if [ -f "$(REDIST_DIR)/$(BFB_FILE)" ]; then \
					cp "$(REDIST_DIR)/$(BFB_FILE)" "$(CANVOS_DIR)/$(BFB_FILE)"; \
					echo "  [OK] $(BFB_FILE)"; \
				else \
					echo "  [FAIL] redist/$(BFB_FILE) not found"; \
					echo "         Download to redist/ from: https://content.mellanox.com/BlueField/BFBs/"; \
					exit 1; \
				fi ;; \
		esac; \
	fi

.PHONY: download
download: ## Download BFB firmware to redist/ (DOCA installed from NVIDIA apt repo)
	@mkdir -p $(REDIST_DIR)
	@echo "=== Downloading firmware to redist/ ==="
	@echo "  [INFO] DOCA $(DOCA_VERSION) — installed from NVIDIA apt repo during build (no download needed)"
	@if [ -f "$(REDIST_DIR)/$(BFB_NAME)" ]; then \
		echo "  [SKIP] $(BFB_NAME) already exists ($$(du -h "$(REDIST_DIR)/$(BFB_NAME)" | cut -f1))"; \
	else \
		echo "  Downloading $(BFB_NAME)..."; \
		curl -fSL -o "$(REDIST_DIR)/$(BFB_NAME)" "$(BFB_URL)"; \
		echo "  [OK] $(BFB_NAME) ($$(du -h "$(REDIST_DIR)/$(BFB_NAME)" | cut -f1))"; \
	fi

.PHONY: configure
configure: ## Generate CanvOS/.arg configured for Edge Appliance build
	@echo "=== Generating $(ARG_FILE) ==="
	@{ \
	echo "CUSTOM_TAG=$(CUSTOM_TAG)"; \
	echo "IMAGE_REGISTRY=$(IMAGE_REGISTRY)"; \
	echo "OS_DISTRIBUTION=$(OS_DISTRIBUTION)"; \
	echo "IMAGE_REPO=$(IMAGE_REPO)"; \
	echo "OS_VERSION=$(OS_VERSION)"; \
	echo "K8S_DISTRIBUTION=$(K8S_DISTRIBUTION)"; \
	echo "ISO_NAME=$(ISO_NAME)"; \
	echo "ARCH=$(ARCH)"; \
	echo "HTTPS_PROXY="; \
	echo "HTTP_PROXY="; \
	echo "UPDATE_KERNEL=$(UPDATE_KERNEL)"; \
	echo "CLUSTERCONFIG=spc.tgz"; \
	echo "CIS_HARDENING=false"; \
	echo "EDGE_CUSTOM_CONFIG=.edge-custom-config.yaml"; \
	echo "FORCE_INTERACTIVE_INSTALL=false"; \
	echo "EDGE_APPLIANCE=$(EDGE_APPLIANCE)"; \
	echo "DOCA_VERSION=$(DOCA_VERSION)"; \
	echo "BFB_PATH=$(BFB_FILE)"; \
	echo "BFB_FILENAME=$(shell basename $(BFB_FILE))"; \
	} > $(ARG_FILE)
	@echo "Generated $(ARG_FILE)"
	@echo ""
	@echo "Configuration:"
	@grep -v '^\s*$$\|^#' $(ARG_FILE) | sed 's/^/  /'

.PHONY: info
info: ## Show current build configuration
	@echo "=== Edge Appliance Build Configuration ==="
	@echo ""
	@echo "  OS:               $(OS_DISTRIBUTION) $(OS_VERSION)"
	@echo "  K8s:              $(K8S_DISTRIBUTION) $(K8S_VERSION)"
	@echo "  Arch:             $(ARCH)"
	@echo "  PE Version:       $(PE_VERSION)"
	@echo "  Custom Tag:       $(CUSTOM_TAG)"
	@echo "  Registry:         $(IMAGE_REGISTRY)"
	@echo "  Edge Appliance:   $(EDGE_APPLIANCE)"
	@echo ""
	@echo "  Provider Image:   $(PROVIDER_IMAGE)"
	@echo "  Installer ISO:    $(BUILD_DIR)/$(ISO_NAME).iso"
	@echo ""
	@echo "  DOCA:             $(DOCA_VERSION) (from NVIDIA apt repo)"
	@echo "  GPU driver:       nvidia-open (from CUDA apt repo)"
	@echo "  BFB firmware:     $(BFB_FILE)"
	@echo ""
	@echo "  src/ files:"
	@for f in $(OVERLAY_FILES); do \
		if [ -f "$(SRC_DIR)/$$f" ]; then \
			echo "    [OK] src/$$f"; \
		else \
			echo "    [MISSING] src/$$f"; \
		fi; \
	done
	@echo ""
	@echo "  Firmware:"
	@case "$(BFB_FILE)" in \
		http://*|https://*) echo "    [URL] $(BFB_FILE)" ;; \
		*) \
			if [ -f "$(REDIST_DIR)/$(BFB_FILE)" ]; then \
				echo "    [OK] redist/$(BFB_FILE) ($$(du -h "$(REDIST_DIR)/$(BFB_FILE)" | cut -f1))"; \
			else \
				echo "    [MISSING] redist/$(BFB_FILE)"; \
			fi ;; \
	esac
	@echo ""
	@echo "  CanvOS/ applied:"
	@if [ -f "$(CANVOS_DIR)/Dockerfile" ] && diff -q "$(SRC_DIR)/Dockerfile" "$(CANVOS_DIR)/Dockerfile" >/dev/null 2>&1; then \
		echo "    [OK] Files match (setup applied)"; \
	else \
		echo "    [STALE] Run 'make setup' to apply"; \
	fi

##@ Prerequisites
.PHONY: check-prereqs
check-prereqs: ## Verify all build prerequisites
	@echo "=== Checking prerequisites ==="
	@PASS=true; \
	echo ""; \
	echo "Docker:"; \
	if command -v docker >/dev/null 2>&1; then \
		echo "  [OK] $$(docker --version)"; \
	else \
		echo "  [FAIL] Docker not found"; PASS=false; \
	fi; \
	echo ""; \
	echo "Disk space:"; \
	AVAIL=$$(df -BG --output=avail $(CURDIR) | tail -1 | tr -dc '0-9'); \
	if [ "$$AVAIL" -ge $(MIN_DISK_GB) ]; then \
		echo "  [OK] $${AVAIL}GB available (minimum $(MIN_DISK_GB)GB)"; \
	else \
		echo "  [FAIL] Only $${AVAIL}GB available (need $(MIN_DISK_GB)GB)"; PASS=false; \
	fi; \
	echo ""; \
	echo "CanvOS clone:"; \
	if [ -f "$(CANVOS_DIR)/Earthfile" ]; then \
		echo "  [OK] CanvOS/ exists"; \
	else \
		echo "  [FAIL] CanvOS/ not found — clone it first"; PASS=false; \
	fi; \
	echo ""; \
	echo "Source files:"; \
	for f in $(OVERLAY_FILES); do \
		if [ -f "$(SRC_DIR)/$$f" ]; then \
			echo "  [OK] src/$$f"; \
		else \
			echo "  [FAIL] src/$$f missing"; PASS=false; \
		fi; \
	done; \
	echo ""; \
	echo "Firmware:"; \
	echo "  [OK] DOCA $(DOCA_VERSION): installed from NVIDIA apt repo during build"; \
	echo "  [OK] nvidia-open: installed from CUDA apt repo during build"; \
	case "$(BFB_FILE)" in \
		http://*|https://*) echo "  [OK] BFB: URL (downloaded during build)" ;; \
		*) \
			if [ -f "$(REDIST_DIR)/$(BFB_FILE)" ]; then \
				echo "  [OK] redist/$(BFB_FILE) ($$(du -h "$(REDIST_DIR)/$(BFB_FILE)" | cut -f1))"; \
			else \
				echo "  [FAIL] redist/$(BFB_FILE) not found"; \
				echo "         Download to redist/ from: https://content.mellanox.com/BlueField/BFBs/"; \
				PASS=false; \
			fi ;; \
	esac; \
	echo ""; \
	if [ "$$PASS" = "true" ]; then \
		echo "All prerequisites met."; \
	else \
		echo "PREREQUISITES NOT MET — fix the issues above before building."; \
		exit 1; \
	fi

##@ Build

# Helper: collect build artifacts from CanvOS/build/ to top-level build/
define collect-artifacts
	@mkdir -p $(BUILD_DIR)
	@if [ -d "$(CANVOS_DIR)/build" ] && [ "$$(ls -A $(CANVOS_DIR)/build 2>/dev/null)" ]; then \
		cp -a $(CANVOS_DIR)/build/* $(BUILD_DIR)/; \
		echo ""; \
		echo "=== Artifacts collected to build/ ==="; \
		ls -lh $(BUILD_DIR)/ | tail -n +2 | sed 's/^/  /'; \
	fi
endef

.PHONY: build
build: ## Build provider image + installer ISO
	@$(MAKE) --no-print-directory setup
	@$(MAKE) --no-print-directory setup-firmware
	@$(MAKE) --no-print-directory configure
	@echo ""
	@echo "=== Building Edge Appliance image ==="
	@echo "  Provider: $(PROVIDER_IMAGE)"
	@echo "  ISO:      $(BUILD_DIR)/$(ISO_NAME).iso"
	@echo ""
	cd $(CANVOS_DIR) && ./earthly.sh +build-all-images --ARCH=$(ARCH) --K8S_VERSION=$(K8S_VERSION)
	$(collect-artifacts)

.PHONY: build-provider
build-provider: ## Build provider image only (no ISO)
	@$(MAKE) --no-print-directory setup
	@$(MAKE) --no-print-directory setup-firmware
	@$(MAKE) --no-print-directory configure
	@echo ""
	@echo "=== Building provider image ==="
	@echo "  Image: $(PROVIDER_IMAGE)"
	@echo ""
	cd $(CANVOS_DIR) && ./earthly.sh +build-provider-images --ARCH=$(ARCH) --K8S_VERSION=$(K8S_VERSION)
	$(collect-artifacts)

.PHONY: build-iso
build-iso: ## Build installer ISO only
	@$(MAKE) --no-print-directory setup
	@$(MAKE) --no-print-directory setup-firmware
	@$(MAKE) --no-print-directory configure
	@echo ""
	@echo "=== Building installer ISO ==="
	@echo "  ISO: $(BUILD_DIR)/$(ISO_NAME).iso"
	@echo ""
	cd $(CANVOS_DIR) && ./earthly.sh +iso --ARCH=$(ARCH) --K8S_VERSION=$(K8S_VERSION)
	$(collect-artifacts)

.PHONY: push
push: ## Build and push provider image to registry
	@$(MAKE) --no-print-directory setup
	@$(MAKE) --no-print-directory setup-firmware
	@$(MAKE) --no-print-directory configure
	@echo ""
	@echo "=== Building and pushing provider image ==="
	@echo "  Image: $(PROVIDER_IMAGE)"
	@echo ""
	cd $(CANVOS_DIR) && ./earthly.sh --push +build-all-images --ARCH=$(ARCH) --K8S_VERSION=$(K8S_VERSION)
	$(collect-artifacts)

.PHONY: build-local
build-local: download build ## Download firmware to redist/, then build from local files

.PHONY: build-url
build-url: ## Build using URLs (no local firmware needed)
	@$(MAKE) --no-print-directory build BFB_FILE=$(BFB_URL)

.PHONY: push-url
push-url: ## Build and push using URLs
	@$(MAKE) --no-print-directory push BFB_FILE=$(BFB_URL)

##@ Verification
.PHONY: verify
verify: ## Verify built image contents (DOCA, BFB, nodeprep, overlays)
	@echo "=== Verifying image: $(PROVIDER_IMAGE) ==="
	@echo ""
	@BFB_NAME=$$(basename "$(BFB_FILE)"); \
	PASS=true; \
	echo "--- DOCA packages ---"; \
	if docker run --rm $(PROVIDER_IMAGE) dpkg -l 2>/dev/null | grep -q doca; then \
		echo "  [OK] DOCA packages installed:"; \
		docker run --rm $(PROVIDER_IMAGE) dpkg -l 2>/dev/null | grep doca | head -5 | sed 's/^/    /'; \
		echo "    ..."; \
	else \
		echo "  [FAIL] No DOCA packages found"; PASS=false; \
	fi; \
	echo ""; \
	echo "--- BFB firmware ---"; \
	if docker run --rm $(PROVIDER_IMAGE) test -f "/opt/spectrocloud/spcx/bfb/$$BFB_NAME" 2>/dev/null; then \
		BFB_SIZE=$$(docker run --rm $(PROVIDER_IMAGE) du -h "/opt/spectrocloud/spcx/bfb/$$BFB_NAME" 2>/dev/null | cut -f1); \
		echo "  [OK] $$BFB_NAME ($$BFB_SIZE)"; \
	else \
		echo "  [FAIL] BFB firmware not found at /opt/spectrocloud/spcx/bfb/$$BFB_NAME"; PASS=false; \
	fi; \
	echo ""; \
	echo "--- Nodeprep script ---"; \
	if docker run --rm $(PROVIDER_IMAGE) test -x /opt/spectrocloud/nodeprep.sh 2>/dev/null; then \
		echo "  [OK] /opt/spectrocloud/nodeprep.sh (executable)"; \
		echo "  Immutable OS detection:"; \
		docker run --rm $(PROVIDER_IMAGE) grep -n 'IS_IMMUTABLE' /opt/spectrocloud/nodeprep.sh 2>/dev/null | head -3 | sed 's/^/    /'; \
	else \
		echo "  [FAIL] nodeprep.sh not found or not executable"; PASS=false; \
	fi; \
	echo ""; \
	echo "--- Overlay configs ---"; \
	for f in /etc/modprobe.d/blacklist-nouveau.conf /etc/modprobe.d/ib_core.conf /etc/lldpd.d/rcp-lldpd.conf /etc/modules-load.d/nfsrdma.conf; do \
		if docker run --rm $(PROVIDER_IMAGE) test -f "$$f" 2>/dev/null; then \
			echo "  [OK] $$f"; \
		else \
			echo "  [FAIL] $$f missing"; PASS=false; \
		fi; \
	done; \
	echo ""; \
	echo "--- GCC compiler ---"; \
	GCC_VER=$$(echo $(OS_VERSION) | grep -q "^24" && echo "14" || echo "12"); \
	if docker run --rm $(PROVIDER_IMAGE) which gcc-$$GCC_VER >/dev/null 2>&1; then \
		echo "  [OK] gcc-$$GCC_VER found"; \
	else \
		echo "  [FAIL] gcc-$$GCC_VER not found"; PASS=false; \
	fi; \
	echo ""; \
	echo "--- Kernel version ---"; \
	KVER=$$(docker run --rm $(PROVIDER_IMAGE) ls /lib/modules/ 2>/dev/null | head -1); \
	echo "  Kernel modules: $$KVER"; \
	if [ "$(EDGE_APPLIANCE)" = "true" ]; then \
		if echo "$$KVER" | grep -qE "^6\.(14|17)\."; then \
			echo "  [OK] Kernel $$KVER (DOCA $(DOCA_VERSION) DKMS compatible)"; \
		else \
			echo "  [WARN] Untested kernel for Edge Appliance: $$KVER"; \
		fi; \
	else \
		if echo "$$KVER" | grep -qE "^6\.(8|5|14)\."; then \
			echo "  [OK] Kernel $$KVER"; \
		elif echo "$$KVER" | grep -qE "^6\.1[0-9]\."; then \
			echo "  [WARN] HWE kernel detected — DOCA DKMS may not work"; \
		else \
			echo "  [INFO] Kernel version: $$KVER"; \
		fi; \
	fi; \
	echo ""; \
	if [ "$(EDGE_APPLIANCE)" = "true" ]; then \
		echo "--- NVIDIA GPU driver ---"; \
		if docker run --rm $(PROVIDER_IMAGE) dpkg -l nvidia-driver-580-open 2>/dev/null | grep -q "^ii"; then \
			NVER=$$(docker run --rm $(PROVIDER_IMAGE) dpkg -l nvidia-driver-580-open 2>/dev/null | awk '/^ii/{print $$3}'); \
			echo "  [OK] nvidia-driver-580-open $$NVER"; \
		else \
			echo "  [FAIL] nvidia-driver-580-open not found"; PASS=false; \
		fi; \
		echo ""; \
		echo "--- DKMS modules ---"; \
		DKMS_OUT=$$(docker run --rm $(PROVIDER_IMAGE) dkms status 2>/dev/null); \
		if [ -n "$$DKMS_OUT" ]; then \
			echo "$$DKMS_OUT" | sed 's/^/  /'; \
			if echo "$$DKMS_OUT" | grep -q "installed"; then \
				echo "  [OK] DKMS modules installed"; \
			else \
				echo "  [WARN] DKMS modules present but not in 'installed' state"; \
			fi; \
		else \
			echo "  [WARN] No DKMS modules found"; \
		fi; \
		echo ""; \
	fi; \
	if [ "$$PASS" = "true" ]; then \
		echo "All verifications passed."; \
	else \
		echo "VERIFICATION FAILED — check errors above."; \
		exit 1; \
	fi

.PHONY: verify-iso
verify-iso: ## Check that installer ISO was built
	@echo "=== Verifying installer ISO ==="
	@if [ -f "$(BUILD_DIR)/$(ISO_NAME).iso" ]; then \
		SIZE=$$(du -h "$(BUILD_DIR)/$(ISO_NAME).iso" | cut -f1); \
		echo "  [OK] $(ISO_NAME).iso ($$SIZE)"; \
		if [ -f "$(BUILD_DIR)/$(ISO_NAME).iso.sha256" ]; then \
			echo "  [OK] SHA256: $$(cat "$(BUILD_DIR)/$(ISO_NAME).iso.sha256")"; \
		fi; \
	else \
		echo "  [FAIL] $(BUILD_DIR)/$(ISO_NAME).iso not found"; \
		exit 1; \
	fi

.PHONY: test
test: verify verify-iso ## Run all verification checks (image + ISO)
	@echo ""
	@echo "All tests passed."

.PHONY: smoke-test
smoke-test: ## Launch QEMU VM from installer ISO for smoke testing
	@if [ ! -f "$(BUILD_DIR)/$(ISO_NAME).iso" ]; then \
		echo "[FAIL] $(BUILD_DIR)/$(ISO_NAME).iso not found — run 'make build' or 'make build-iso' first"; \
		exit 1; \
	fi
	@echo "=== Launching QEMU smoke test ==="
	@echo "  ISO: $(BUILD_DIR)/$(ISO_NAME).iso"
	@echo "  Memory: $${MEMORY:-10096}MB  Cores: $${CORES:-5}"
	@echo ""
	@echo "  Boot the VM in 'Kairos (manual)' mode to test nodeprep."
	@echo "  Press Ctrl+A X to exit QEMU."
	@echo ""
	cd $(CANVOS_DIR)/hack && ./launch-qemu.sh $(BUILD_DIR)/$(ISO_NAME).iso

.PHONY: smoke-test-auto
smoke-test-auto: ## Automated QEMU smoke test (non-interactive, pass/fail)
	@if [ ! -f "$(BUILD_DIR)/$(ISO_NAME).iso" ]; then \
		echo "[FAIL] $(BUILD_DIR)/$(ISO_NAME).iso not found — run 'make build' or 'make build-iso' first"; \
		exit 1; \
	fi
	$(SRC_DIR)/hack/smoke-test-auto.sh $(BUILD_DIR)/$(ISO_NAME).iso

##@ Cleanup
.PHONY: clean
clean: ## Full cleanup: build artifacts, images, redist/, revert CanvOS/
	@echo "=== Cleaning build artifacts ==="
	sudo rm -rf $(BUILD_DIR)
	sudo rm -rf $(CANVOS_DIR)/build
	@echo "  Removed build/"
	@echo "=== Removing Docker images ==="
	-@docker rmi $(PROVIDER_IMAGE) 2>/dev/null || true
	-@docker rmi $(PROVIDER_IMAGE)_linux_$(ARCH) 2>/dev/null || true
	-@docker rmi $(INSTALLER_IMAGE) 2>/dev/null || true
	-@docker rmi $(INSTALLER_IMAGE)_linux_$(ARCH) 2>/dev/null || true
	@echo "=== Clearing redist/ ==="
	rm -rf $(REDIST_DIR)
	@echo "  Removed $(REDIST_DIR)/"
	@echo "=== Reverting CanvOS/ to upstream ==="
	@cd $(CANVOS_DIR) && git restore Dockerfile Earthfile .arg.template .gitignore 2>/dev/null || true
	@rm -f $(CANVOS_DIR)/overlay/files/opt/spectrocloud/nodeprep.sh
	@rm -f $(CANVOS_DIR)/overlay/files/etc/modprobe.d/blacklist-nouveau.conf
	@rm -f $(CANVOS_DIR)/overlay/files/etc/modprobe.d/ib_core.conf
	@rm -f $(CANVOS_DIR)/overlay/files/etc/lldpd.d/rcp-lldpd.conf
	@rm -f $(CANVOS_DIR)/overlay/files/etc/modules-load.d/nfsrdma.conf
	@rm -f $(CANVOS_DIR)/.arg
	@rm -f $(CANVOS_DIR)/$(BFB_NAME)
	@rm -f $(CANVOS_DIR)/EDGE-APPLIANCE-BUILD.md $(CANVOS_DIR)/CLAUDE.md
	@echo "  CanvOS/ reverted to upstream."
	@echo ""
	@echo "Clean complete."

.PHONY: clean-earthly
clean-earthly: ## Stop and remove Earthly buildkit container and cache
	@echo "=== Cleaning Earthly ==="
	-docker stop earthly-buildkitd 2>/dev/null
	-docker rm earthly-buildkitd 2>/dev/null
	-docker volume rm earthly-tmp 2>/dev/null
	@echo "Done."

##@ Quick Start
.PHONY: all
all: check-prereqs build test ## Full pipeline: check prereqs, build, test
	@echo ""
	@echo "=== Build complete ==="
	@echo "  Provider: $(PROVIDER_IMAGE)"
	@echo "  ISO:      $(BUILD_DIR)/$(ISO_NAME).iso"

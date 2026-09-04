# ==============================================================================
# Makefile for Debian NAS Build (Zyxel NAS5xx / OpenMediaVault 7)
# ==============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := all

# User-configurable parameters
MODEL       ?= nas542
OMV         ?= true
HOSTNAME    ?= debian-nas
RUNTIME     ?= auto
SUDO        ?= auto
DISK        ?=

# Tested Linux 6.12 NAS5xx Kernel package
KERNEL_VERSION := 6.12.95-20260823
KERNEL_ZIP     := linux-image-$(KERNEL_VERSION)-nas5xx-armhf.zip
KERNEL_URL     := https://github.com/scpcom/linux/releases/download/v6.12.95-7018-sbc/$(KERNEL_ZIP)

# Container dependencies
CONTAINER_PKGS := fdisk dosfstools e2fsprogs gdisk rsync binutils parted unzip debootstrap qemu-user-static binfmt-support whiptail patch wget gnupg ca-certificates python3-minimal

# Map model to factory firmware download URL
FW_URL_nas542  := ftp://ftp.zyxel.com/NAS542/firmware/NAS542_V5.21(ABAG.0)C0.zip
FW_URL_nas540  := ftp://ftp.zyxel.com/NAS540/firmware/NAS540_V5.21(AATB.0)C0.zip
FW_URL_nas520  := ftp://ftp.zyxel.com/NAS520/firmware/NAS520_V5.21(AASZ.0)C0.zip
FW_URL_nas326  := ftp://ftp.zyxel.com/NAS326/firmware/NAS326_V5.21(AAZF.0)C0.zip
FW_URL_nsa325  := ftp://ftp.zyxel.com/NSA325/firmware/NSA325_V4.81(AAAJ.0)C0.zip
FW_URL_nsa320s := ftp://ftp.zyxel.com/NSA320S/firmware/NSA320S_V4.75(AANV.1)C0.zip
FW_URL_nsa310s := ftp://ftp.zyxel.com/NSA310S/firmware/NSA310S_V4.75(AALH.1)C0.zip
FW_URL         := $(FW_URL_$(MODEL))

# Helper macro to resolve container engine command (podman or docker)
define get_container_cmd
	if [ "$(RUNTIME)" = "auto" ]; then \
		if command -v podman >/dev/null 2>&1; then \
			ENGINE="podman"; \
		elif command -v docker >/dev/null 2>&1; then \
			ENGINE="docker"; \
		else \
			echo "ERROR: Neither 'podman' nor 'docker' is installed."; exit 1; \
		fi; \
	else \
		ENGINE="$(RUNTIME)"; \
	fi; \
	CMD=""; \
	if [ "$(SUDO)" = "true" ] || { [ "$(SUDO)" = "auto" ] && [ "$$EUID" -ne 0 ]; }; then \
		CMD="sudo "; \
	fi; \
	echo "$${CMD}$${ENGINE}"
endef

.PHONY: all full image diskimage prep shell interactive clean flash help

# ------------------------------------------------------------------------------
# Primary Targets
# ------------------------------------------------------------------------------

all: full ## Build complete Debian 12 + OMV 7 image from scratch (default)

full: prep ## Build full OS and disk image in batch mode
	@ENGINE_CMD=$$($(call get_container_cmd)); \
	echo "=== Launching build environment via $$ENGINE_CMD ==="; \
	$$ENGINE_CMD run --rm -it --privileged \
		-v /dev:/dev \
		-v "$$(pwd)":/build \
		-w /build \
		debian:bookworm \
		bash -c "apt-get update && apt-get install -y $(CONTAINER_PKGS) && ./build-debian.sh batch"
	@echo ""; \
	echo "=== Build finished ==="; \
	if compgen -G "images/*.img.gz" > /dev/null; then \
		echo "Generated disk image(s):"; \
		ls -lh images/*.img.gz; \
	fi

image: diskimage ## Alias for diskimage
diskimage: ## Fast rebuild of USB disk image from existing armhf/ tree (~30s)
	@ENGINE_CMD=$$($(call get_container_cmd)); \
	echo "=== Rebuilding disk image via $$ENGINE_CMD ==="; \
	$$ENGINE_CMD run --rm -it --privileged \
		-v /dev:/dev \
		-v "$$(pwd)":/build \
		-w /build \
		debian:bookworm \
		bash -c "apt-get update && apt-get install -y $(CONTAINER_PKGS) && ./build-debian.sh diskimage"
	@echo ""; \
	echo "=== Build finished ==="; \
	if compgen -G "images/*.img.gz" > /dev/null; then \
		echo "Generated disk image(s):"; \
		ls -lh images/*.img.gz; \
	fi

interactive: prep ## Run build with interactive whiptail menus inside container
	@ENGINE_CMD=$$($(call get_container_cmd)); \
	$$ENGINE_CMD run --rm -it --privileged \
		-v /dev:/dev \
		-v "$$(pwd)":/build \
		-w /build \
		debian:bookworm \
		bash -c "apt-get update && apt-get install -y $(CONTAINER_PKGS) && ./build-debian.sh"

shell: ## Drop into an interactive container bash shell
	@ENGINE_CMD=$$($(call get_container_cmd)); \
	$$ENGINE_CMD run --rm -it --privileged \
		-v /dev:/dev \
		-v "$$(pwd)":/build \
		-w /build \
		debian:bookworm \
		bash -c "apt-get update && apt-get install -y $(CONTAINER_PKGS) && exec bash"

# ------------------------------------------------------------------------------
# Prerequisites Preparation
# ------------------------------------------------------------------------------

prep: ## Prepare prerequisites (archives, kernel zip, and config)
	@echo "=== [1/3] Preparing Bookworm init scripts ==="
	@mkdir -p archives
	@if [ ! -e archives/debian-bookworm-init-scripts.tar.gz ]; then \
		if [ -e archives/debian-bullseye-init-scripts.tar.gz ]; then \
			echo "Linking archives/debian-bookworm-init-scripts.tar.gz -> debian-bullseye-init-scripts.tar.gz"; \
			ln -sf debian-bullseye-init-scripts.tar.gz archives/debian-bookworm-init-scripts.tar.gz; \
		else \
			echo "WARNING: archives/debian-bullseye-init-scripts.tar.gz is missing!"; \
		fi; \
	else \
		echo "Bookworm init scripts archive present."; \
	fi
	@echo "=== [2/3] Checking Linux kernel package ==="
	@mkdir -p kernel
	@FOUND_KRN=$$(ls kernel/linux-image-*-armhf.zip 2>/dev/null | head -n1 || true); \
	if [ -z "$$FOUND_KRN" ]; then \
		echo "Downloading tested Linux 6.12 NAS5xx kernel..."; \
		if command -v wget >/dev/null 2>&1; then \
			wget -q --show-progress -O "kernel/$(KERNEL_ZIP)" "$(KERNEL_URL)"; \
		elif command -v curl >/dev/null 2>&1; then \
			curl -L --progress-bar -o "kernel/$(KERNEL_ZIP)" "$(KERNEL_URL)"; \
		else \
			echo "ERROR: Neither 'wget' nor 'curl' is installed to download kernel."; exit 1; \
		fi; \
		echo "Kernel download complete: kernel/$(KERNEL_ZIP)"; \
	else \
		echo "Using kernel package: $$FOUND_KRN"; \
	fi
	@echo "=== [3/3] Generating build configuration ==="
	@mkdir -p etc
	@if [ ! -f etc/debian-build.conf ]; then \
		printf "boardModel=%s\nFWGETURL=\"%s\"\nFWUSEVER=\"newer\"\nfanSpeed=keep\nfirstUser=share\nimageMdMount=false\nimageOmv=%s\nimageOmvInit=%s\nimageHostname=%s\nimageEth0Ip=dhcp\nimageEth0Mask=255.255.255.0\nimageEth1Ip=dhcp\nimageEth1Mask=255.255.255.0\nimageRouter=\nimageDNS=\ninstallRecommends=1\ninstallISCSITarget=0\ninstallMailServer=1\ninstallNFSServer=1\ninstallNTPServer=0\ninstallSMBServer=1\ninstallMiscServer=1\ninstallWifi=0\ninstallIpmitool=0\ninstallSmartctl=1\n" \
			"$(MODEL)" "$(FW_URL)" "$(OMV)" "$(OMV)" "$(HOSTNAME)" > etc/debian-build.conf; \
		echo "Created etc/debian-build.conf (Model: $(MODEL), OMV: $(OMV))"; \
	else \
		echo "Using existing etc/debian-build.conf"; \
	fi
	@echo "Prerequisites prepared successfully."

# ------------------------------------------------------------------------------
# Flashing Target
# ------------------------------------------------------------------------------

flash: ## Flash latest built image to USB drive (Usage: make flash DISK=/dev/sdX)
	@if [ -z "$(DISK)" ]; then \
		echo "ERROR: DISK variable is required."; \
		echo "Usage: make flash DISK=/dev/sdX"; \
		echo ""; \
		echo "Available removable block devices:"; \
		lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E 'usb|TRAN' || lsblk; \
		exit 1; \
	fi
	@if [ ! -b "$(DISK)" ]; then \
		echo "ERROR: '$(DISK)' is not a valid block device."; exit 1; \
	fi
	@LATEST_IMG=$$(ls -t images/*.img.gz 2>/dev/null | head -n1); \
	if [ -z "$$LATEST_IMG" ]; then \
		echo "ERROR: No image found in images/. Run 'make' first."; exit 1; \
	fi; \
	echo "Target disk: $(DISK)"; \
	echo "Image file:  $$LATEST_IMG"; \
	echo ""; \
	read -p "WARNING: All data on $(DISK) will be DESTROYED. Continue? [y/N] " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "Flashing to $(DISK)..."; \
		zcat "$$LATEST_IMG" | sudo dd of=$(DISK) bs=4M status=progress conv=fsync; \
		sync; \
		echo "Flashing complete! You can now insert $(DISK) into your NAS."; \
	else \
		echo "Flashing aborted."; exit 1; \
	fi

# ------------------------------------------------------------------------------
# Clean Action
# ------------------------------------------------------------------------------

clean: ## Clean generated disk images and temporary build artifacts
	@echo "Cleaning temporary build artifacts and images..."
	@rm -rf images/*
	@rm -f armhf/tmp/*
	@echo "Clean complete."

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------

help: ## Show this help message
	@echo "Debian NAS Build System"
	@echo ""
	@echo "Usage:"
	@echo "  make [target] [VARIABLE=value]"
	@echo ""
	@echo "Common Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  MODEL       Target NAS hardware (default: nas542)"
	@echo "              Supported: nas542, nas540, nas520, nas326, nsa325, nsa320s, nsa310s"
	@echo "  OMV         Include OpenMediaVault 7 (default: true, set false for minimal Debian)"
	@echo "  HOSTNAME    System hostname (default: debian-nas)"
	@echo "  RUNTIME     Container runtime (default: auto, or podman, docker)"
	@echo "  SUDO        Prepend container command with sudo (default: auto, or true, false)"
	@echo "  DISK        Target USB device for 'make flash' (e.g., /dev/sdb)"
	@echo ""
	@echo "Examples:"
	@echo "  make                     # Full automated build for NAS542"
	@echo "  make image               # Fast rebuild of USB image (~30s)"
	@echo "  make MODEL=nas540        # Build for NAS540"
	@echo "  make flash DISK=/dev/sdc # Flash latest image to /dev/sdc"

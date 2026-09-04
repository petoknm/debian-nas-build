# ==============================================================================
# Makefile for Debian NAS Build (Zyxel NAS5xx / OpenMediaVault 7)
# ==============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := all

# Configurable variables
MODEL     ?= nas542
OMV       ?= true
HOSTNAME  ?= debian-nas
RUNTIME   ?= # auto-detects podman or docker

# Build flags passed to build.sh
BUILD_FLAGS := --model $(MODEL) --hostname $(HOSTNAME)
ifeq ($(OMV),false)
	BUILD_FLAGS += --no-omv
endif
ifneq ($(RUNTIME),)
	BUILD_FLAGS += --$(RUNTIME)
endif

.PHONY: all full image diskimage prep shell clean flash help

# ------------------------------------------------------------------------------
# Primary Targets
# ------------------------------------------------------------------------------

all: full ## Build complete Debian 12 + OMV 7 image from scratch (default)

full: prep ## Build full OS and disk image in batch mode
	@./build.sh full $(BUILD_FLAGS)

image: diskimage ## Alias for diskimage
diskimage: ## Fast rebuild of USB disk image from existing armhf/ tree (~30s)
	@./build.sh image

prep: ## Download tested kernel and prepare config & init archives
	@./build.sh prep $(BUILD_FLAGS)

shell: ## Launch interactive bash shell inside the build container
	@./build.sh shell $(BUILD_FLAGS)

clean: ## Clean generated disk images and temporary build artifacts
	@./build.sh clean

# ------------------------------------------------------------------------------
# Flashing Target
# ------------------------------------------------------------------------------

flash: ## Flash the latest built image to USB drive (Usage: make flash DISK=/dev/sdX)
	@if [ -z "$(DISK)" ]; then \
		echo "ERROR: DISK variable is required."; \
		echo "Usage: make flash DISK=/dev/sdX"; \
		echo "Available removable drives:"; \
		lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E 'usb|TRAN' || lsblk; \
		exit 1; \
	fi
	@if [ ! -b "$(DISK)" ]; then \
		echo "ERROR: $(DISK) is not a valid block device."; \
		exit 1; \
	fi
	@LATEST_IMG=$$(ls -t images/*.img.gz 2>/dev/null | head -n1); \
	if [ -z "$$LATEST_IMG" ]; then \
		echo "ERROR: No image found in images/. Run 'make' or 'make image' first."; \
		exit 1; \
	fi; \
	echo "Target disk: $(DISK)"; \
	echo "Image file:  $$LATEST_IMG"; \
	echo ""; \
	read -p "WARNING: All data on $(DISK) will be DESTROYED. Continue? [y/N] " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "Decompressing and flashing to $(DISK)..."; \
		zcat "$$LATEST_IMG" | sudo dd of=$(DISK) bs=4M status=progress conv=fsync; \
		sync; \
		echo "Flashing complete! You can now insert $(DISK) into your NAS."; \
	else \
		echo "Flashing aborted."; \
		exit 1; \
	fi

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
	@echo "              Supported: nas542, nas540, nas520, nas326, nsa325"
	@echo "  OMV         Include OpenMediaVault 7 (default: true, set false for minimal Debian)"
	@echo "  RUNTIME     Container runtime (default: auto-detected, podman or docker)"
	@echo "  DISK        Target USB device for 'make flash' (e.g., /dev/sdb)"
	@echo ""
	@echo "Examples:"
	@echo "  make                     # Full automated build for NAS542"
	@echo "  make image               # Fast rebuild of USB image (~30s)"
	@echo "  make MODEL=nas540        # Build for NAS540"
	@echo "  make flash DISK=/dev/sdc # Flash latest image to /dev/sdc"

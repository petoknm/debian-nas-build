# ==============================================================================
# Makefile for Debian NAS Build (Zyxel NAS5xx / OpenMediaVault 7)
# ==============================================================================
.ONESHELL:
SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := all

IN_CONTAINER ?= 0

# Configuration
-include .config
MODEL        ?= nas542
ENABLE_OMV   ?= true
HOSTNAME     ?= debian-nas
DISK         ?=
ZSTD_LEVEL   ?= 9
MODEL        := $(strip $(subst ",,$(MODEL)))
ENABLE_OMV   := $(strip $(subst ",,$(ENABLE_OMV)))
HOSTNAME     := $(strip $(subst ",,$(HOSTNAME)))

# Linux 6.12 Kernel & Zyxel Firmware
KERNEL_VER   ?= 6.12.95-20260823
KERNEL_ZIP   := linux-image-$(KERNEL_VER)-nas5xx-armhf.zip
KERNEL_URL   := https://github.com/scpcom/linux/releases/download/v6.12.95-7018-sbc/$(KERNEL_ZIP)
FW_URL_nas542 := ftp://ftp.zyxel.com/NAS542/firmware/NAS542_V5.21(ABAG.0)C0.zip
FW_URL_nas540 := ftp://ftp.zyxel.com/NAS540/firmware/NAS540_V5.21(AATB.0)C0.zip
FW_URL_nas520 := ftp://ftp.zyxel.com/NAS520/firmware/NAS520_V5.21(AASZ.0)C0.zip
FW_URL_nas326 := ftp://ftp.zyxel.com/NAS326/firmware/NAS326_V5.21(AAZF.0)C0.zip
FW_URL        := $(FW_URL_$(MODEL))

# Container Runtime
CONTAINER    ?= $(shell if docker info >/dev/null 2>&1; then which docker; else which podman 2>/dev/null; fi)
SUDO         ?= $(if $(shell $(CONTAINER) info >/dev/null 2>&1 && echo ok),,sudo)
BUILDER_IMG  := debian-nas-builder

.PHONY: all full image diskimage bootstrap firmware omv kernel prep menuconfig config shell clean flash help builder-image

# ==============================================================================
# HOST ORCHESTRATION (IN_CONTAINER == 0)
# ==============================================================================
ifeq ($(IN_CONTAINER),0)

.config: .config.default
	@cp $< $@

archives/debian-bookworm-init-scripts.tar.gz: archives/debian-bullseye-init-scripts.tar.gz
	@mkdir -p archives && ln -sf debian-bullseye-init-scripts.tar.gz $@

kernel/$(KERNEL_ZIP):
	@mkdir -p kernel
	curl -Ls -o $@ $(KERNEL_URL) || wget -qO $@ $(KERNEL_URL)

prep: .config archives/debian-bookworm-init-scripts.tar.gz kernel/$(KERNEL_ZIP)

builder-image:
	@if [ -n "$(FORCE)" ] || ! $(CONTAINER) image inspect $(BUILDER_IMG) >/dev/null 2>&1; then
		$(SUDO) $(CONTAINER) build -t $(BUILDER_IMG) -f Containerfile .
	fi

DOCKER_CMD = $(SUDO) $(CONTAINER) run --rm $(if $(shell test -t 0 && echo 1),-it,-i) --privileged -v /dev:/dev -v $(CURDIR):/build -w /build $(BUILDER_IMG) make IN_CONTAINER=1

all: builder-image prep       ## Full automated build from scratch (default)
full: builder-image prep      ## Full automated build pipeline inside container
image: diskimage              ## Alias for diskimage
diskimage: builder-image prep ## Fast rebuild of USB disk image (~30s)
bootstrap: builder-image prep ## Stage 1: Run debootstrap inside container
firmware: builder-image prep  ## Stage 2: Extract Zyxel firmware tools inside container
omv: builder-image prep       ## Stage 3: Install & configure OpenMediaVault 7 inside container
kernel: builder-image prep    ## Stage 4: Deploy Linux 6.12 kernel & NAND flashers inside container

all full diskimage bootstrap firmware omv kernel:
	@$(DOCKER_CMD) $@

shell: builder-image ## Drop into an interactive container shell
	@$(SUDO) $(CONTAINER) run --rm -it --privileged -v /dev:/dev -v $(CURDIR):/build -w /build $(BUILDER_IMG) bash

menuconfig: config ## Alias for config
config: ## Launch interactive Whiptail menu to configure options & update .config
	@./menuconfig.sh

flash: ## Flash latest built image to USB drive (Usage: make flash DISK=/dev/sdX)
	@test -b "$(DISK)" || { echo "ERROR: DISK=/dev/sdX block device required."; exit 1; }
	IMG=$$(ls -t images/*.img.zst images/*.img.gz 2>/dev/null | head -n1 || true)
	test -n "$$IMG" || { echo "ERROR: No image found in images/. Run 'make' first."; exit 1; }
	read -p "Overwrite $(DISK) with $$IMG? [y/N] " -n 1 -r; echo ""
	[[ $$REPLY =~ ^[Yy]$$ ]] || exit 1
	zstd -dc "$$IMG" | sudo dd of=$(DISK) bs=4M status=progress conv=fsync && sync
	echo "Flashing complete!"

clean: ## Clean generated disk images and temporary artifacts
	rm -rf images/* armhf/tmp/*

help: ## Show this help message
	@echo "Usage: make [target] [VARIABLE=value]"
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ==============================================================================
# CONTAINER EXECUTION (IN_CONTAINER == 1)
# ==============================================================================
else

R        := armhf
BOOTDIR  := $(R)/boot
DEFHASH  := $$6$$rAEPV1reSeT/j8P8$$ULVwQssIR35sAyszFnjsoyeBDc21C7m7yBtDX8CjkcR3Kddv1S6v.Cel6umhUiGtCgXbMN1CackdI0vBMf0LU0

all: full
full: bootstrap firmware omv kernel diskimage
	@echo "=== Full Build Complete ==="

bootstrap: armhf/bin/bash
armhf/bin/bash:
	@echo "=== [Stage 1] Debian 12 Bootstrap ==="
	mkdir -p $(R)
	debootstrap --arch=armhf --foreign bookworm $(R) http://deb.debian.org/debian
	cp -p /usr/bin/qemu-arm-static $(R)/usr/bin/ 2>/dev/null || true
	chroot $(R) /debootstrap/debootstrap --second-stage
	printf 'deb http://deb.debian.org/debian bookworm main contrib non-free-firmware\n' > $(R)/etc/apt/sources.list
	echo "$(HOSTNAME)" > $(R)/etc/hostname
	printf 'nameserver 1.1.1.1\n' > $(R)/etc/resolv.conf
	printf 'devpts /dev/pts devpts gid=5,mode=620 0 0\ntmpfs /tmp tmpfs defaults 0 0\n' > $(R)/etc/fstab
	DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get update -qq
	DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get install -y --no-install-recommends \
		systemd systemd-sysv sudo locales tzdata ca-certificates wget curl gnupg kmod dosfstools e2fsprogs fdisk gdisk parted rsync net-tools iproute2 udev

firmware: armhf/firmware/bin/buzzerc
armhf/firmware/bin/buzzerc:
	@echo "=== [Stage 2] Vendor Firmware Extraction ($(MODEL)) ==="
	mkdir -p fw $(R)/firmware/bin $(R)/usr/local/bin
	FW_FILE=fw/$$(basename "$(FW_URL)")
	[ -n "$(FW_URL)" ] && [ ! -f "$$FW_FILE" ] && curl -Ls -o "$$FW_FILE" "$(FW_URL)" || true
	[ -f "$$FW_FILE" ] && unzip -qo "$$FW_FILE" -d fw/unpack 2>/dev/null || true
	for t in buzzerc info_printenv info_setenv bareboxenv flash_erase nandwrite; do
		f=$$(find fw/ -name "$$t" 2>/dev/null | head -n1 || true)
		[ -n "$$f" ] && cp -p "$$f" $(R)/firmware/bin/ && cp -p "$$f" $(R)/usr/local/bin/ || true
	done
	rm -rf fw/unpack

omv:
ifeq ($(ENABLE_OMV),true)
	@echo "=== [Stage 3] OpenMediaVault 7 Install & Tuning ==="
	rm -f $(R)/etc/resolv.conf && printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > $(R)/etc/resolv.conf
	mkdir -p $(R)/etc/apt/trusted.gpg.d $(R)/etc/apt/sources.list.d $(R)/etc/apt/preferences.d
	[ -f $(R)/etc/apt/trusted.gpg.d/openmediavault-archive-keyring.gpg ] || \
		(curl -fsSL https://packages.openmediavault.org/public/archive.key | gpg --dearmor -o $(R)/etc/apt/trusted.gpg.d/openmediavault-archive-keyring.gpg 2>/dev/null || true)
	printf 'deb https://packages.openmediavault.org/public sandworm main\n' > $(R)/etc/apt/sources.list.d/openmediavault.list
	printf 'Package: linux-image-*\nPin: release a=sandworm\nPin-Priority: -1\n' > $(R)/etc/apt/preferences.d/openmediavault-kernel.pref
	mount -t proc proc $(R)/proc 2>/dev/null || true
	mount -t sysfs sys $(R)/sys 2>/dev/null || true
	mount -t devpts devpts $(R)/dev/pts -o gid=5,mode=620 2>/dev/null || true
	trap 'umount -l $(R)/dev/pts $(R)/sys $(R)/proc 2>/dev/null || true' EXIT
	chroot $(R) dpkg -s openmediavault >/dev/null 2>&1 || { \
		DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get update -qq && \
		DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get install -y --no-install-recommends openmediavault openmediavault-md openmediavault-lvm2; }
	chroot $(R) dpkg -s openmediavault-omvextrasorg >/dev/null 2>&1 || ( \
		curl -fsSL -o $(R)/tmp/omvextras.deb https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master/openmediavault-omvextrasorg_latest_all7.deb 2>/dev/null && \
		DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get install -y --no-install-recommends /tmp/omvextras.deb 2>/dev/null || true; \
		rm -f $(R)/tmp/omvextras.deb )
	sed -i -e 's/session required pam_loginuid.so/session optional pam_loginuid.so/' \
	       -e 's/#*PermitRootLogin.*/PermitRootLogin yes/' \
	       -e 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' $(R)/etc/ssh/sshd_config $(R)/etc/pam.d/sshd 2>/dev/null || true
	sed -i 's|^auth.*pam_faillock.so|#&|' $(R)/etc/pam.d/openmediavault* 2>/dev/null || true
	echo 'root:$(DEFHASH)' | chroot $(R) chpasswd -e 2>/dev/null || true
	echo 'admin:$(DEFHASH)' | chroot $(R) chpasswd -e 2>/dev/null || true
	[ -f $(R)/etc/php/8.2/fpm/pool.d/openmediavault-webgui.conf ] && sed -i 's/pm.max_children = .*/pm.max_children = 4/' $(R)/etc/php/8.2/fpm/pool.d/openmediavault-webgui.conf 2>/dev/null || true
	for f in $(R)/var/www/openmediavault/main.*.js ; do [ -f "$$f" ] && sed -i 's/defaultTo(Be,500)/defaultTo(Be,2500)/g' "$$f" 2>/dev/null || true; done
	umount -l $(R)/dev/pts $(R)/sys $(R)/proc 2>/dev/null || true
	chroot $(R) dpkg -s openmediavault >/dev/null
endif

kernel:
	@echo "=== [Stage 4] Deploying Linux 6.12 Kernel & Overlay ==="
	mkdir -p $(BOOTDIR) $(R)/usr/local/bin
	if [ -f kernel/$(KERNEL_ZIP) ]; then
		TMP=$$(mktemp -d)
		unzip -qo kernel/$(KERNEL_ZIP) -d "$$TMP"
		[ -f "$$TMP/uImage" ] && cp -p "$$TMP/uImage" $(BOOTDIR)/ && cp -p "$$TMP/uImage" kernel/ 2>/dev/null || true
		find "$$TMP" -name "*.dtb" -exec cp -p {} $(BOOTDIR)/ \;
		find "$$TMP" -name "*.deb" -exec chroot $(R) dpkg -i --force-depends {} \; 2>/dev/null || true
		rm -rf "$$TMP"
	fi
	cp -a overlay/* $(R)/ 2>/dev/null || true
	chmod +x $(R)/usr/local/bin/zy-* $(R)/debinit.sh 2>/dev/null || true

image: diskimage
diskimage:
	@echo "=== [Stage 5] Generating Disk Image ==="
	mkdir -p images mnt_tmp
	for i in $$(seq 0 7); do [ -e /dev/loop$$i ] || mknod /dev/loop$$i b 7 $$i 2>/dev/null || true; done
	IMG="images/debian-nas-bookworm-$$(date +%y.%j)-armhf.img"
	rm -f "$$IMG" "$${IMG}.zst"
	ROOT_M=$$(( $$(du -sk $(R) | cut -f1) / 1024 + 512 ))
	dd if=/dev/zero of="$$IMG" bs=1M count=1 seek=$$(( 97 + ROOT_M + 32 )) status=none
	sgdisk -o -n 1:2048:+95M -c 1:TC_BOOT -t 1:0700 -u 1:54cdf5da-deb1-b007-a694-32880502ef34 \
	          -n 2:0:+$${ROOT_M}M -c 2:TC_ROOT -t 2:8300 -u 2:54cdf5da-deb1-f007-a694-32880502ef34 "$$IMG" > /dev/null
	BDEV=$$(losetup -o 1M --sizelimit 95M -f --show "$$IMG")
	RDEV=$$(losetup -o 96M --sizelimit $${ROOT_M}M -f --show "$$IMG")
	mkfs.vfat -n TC_BOOT -S 512 -s 16 "$$BDEV" > /dev/null
	mkfs.ext4 -F -O ^metadata_csum -L TC_ROOT -m 0 "$$RDEV" > /dev/null
	mount "$$RDEV" mnt_tmp && mkdir -p mnt_tmp/boot && mount -t vfat "$$BDEV" mnt_tmp/boot
	[ -d archives ] && for f in archives/*-boot*.tar.gz; do [ -e "$$f" ] && tar xzf "$$f" -C $(BOOTDIR) 2>/dev/null; done || true
	[ ! -e $(BOOTDIR)/uImage ] && cp -p kernel/uImage $(BOOTDIR)/ 2>/dev/null || true
	rsync -aHAX --exclude='/boot/*' --exclude='/mnt_tmp' --exclude='/images' $(R)/ mnt_tmp/
	rsync -rtLv --modify-window=1 $(BOOTDIR)/ mnt_tmp/boot/
	grep -q "TC_ROOT" mnt_tmp/etc/fstab || echo 'LABEL=TC_ROOT / ext4 defaults,noatime 0 1' >> mnt_tmp/etc/fstab
	grep -q "TC_BOOT" mnt_tmp/etc/fstab || echo 'LABEL=TC_BOOT /boot vfat defaults,noatime 0 0' >> mnt_tmp/etc/fstab
	sync && umount mnt_tmp/boot mnt_tmp && rm -rf mnt_tmp
	losetup -d "$$BDEV" "$$RDEV"
	zstd -$(ZSTD_LEVEL) -f --rm "$$IMG"
	chown $$(stat -c '%u:%g' images 2>/dev/null || echo 1000:1000) "$${IMG}.zst" 2>/dev/null || true
	echo "Generated: $${IMG}.zst ($$(ls -lh $${IMG}.zst | awk '{print $$5}'))"

endif

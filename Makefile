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
	printf 'deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware\n' > $(R)/etc/apt/sources.list
	printf 'deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware\n' >> $(R)/etc/apt/sources.list
	printf 'deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware\n' >> $(R)/etc/apt/sources.list
	echo "$(HOSTNAME)" > $(R)/etc/hostname
	printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost ip6-loopback\nfe00::0\t\tip6-localnet\nff00::0\t\tip6-mcastprefix\nff02::1\t\tip6-allnodes\nff02::2\t\tip6-allrouters\n127.0.1.1\t$(HOSTNAME)\n' > $(R)/etc/hosts
	printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > $(R)/etc/resolv.conf
	printf 'devpts /dev/pts devpts gid=5,mode=620 0 0\ntmpfs /tmp tmpfs defaults 0 0\n' > $(R)/etc/fstab
	mkdir -p $(R)/etc/network
	printf 'auto lo\niface lo inet loopback\n\nauto eth0\nallow-hotplug eth0\niface eth0 inet dhcp\niface eth0 inet6 manual\n    pre-down ip -6 addr flush dev $$IFACE\n' > $(R)/etc/network/interfaces
	echo "precedence ::ffff:0:0/96  100" >> $(R)/etc/gai.conf 2>/dev/null || true
	printf "postfix postfix/main_mailer_type select No configuration\nproftpd-basic shared/proftpd/inetd_or_standalone select standalone\n" | chroot $(R) debconf-set-selections
	printf '#!/bin/sh\nexit 101\n' > $(R)/usr/sbin/policy-rc.d && chmod +x $(R)/usr/sbin/policy-rc.d
	mount -t proc proc $(R)/proc 2>/dev/null || true
	mount -t sysfs sys $(R)/sys 2>/dev/null || true
	mount -t devpts devpts $(R)/dev/pts -o gid=5,mode=620 2>/dev/null || true
	trap 'umount -l $(R)/dev/pts $(R)/sys $(R)/proc 2>/dev/null || true; rm -f $(R)/usr/sbin/policy-rc.d' EXIT
	DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get update -qq
	DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get install -y --no-install-recommends \
		systemd systemd-sysv sudo locales tzdata ca-certificates wget curl gnupg kmod dosfstools e2fsprogs fdisk gdisk parted rsync net-tools iproute2 udev \
		avahi-daemon snmpd proftpd-basic tftpd-hpa winbind samba-common-bin attr irqbalance \
		fake-hwclock i2c-tools mtd-utils watchdog dphys-swapfile \
		screen strace tcpdump telnet traceroute u-boot-tools usbutils usb-modeswitch \
		vim nano p7zip-full zip unzip xz-utils bzip2 less cifs-utils smbclient \
		ethtool hdparm sdparm at anacron cron logrotate bsd-mailx postfix wsdd fail2ban \
		bc dc busybox-static dnsmasq-base bind9-dnsutils eject gdbserver gettext-base ifupdown initramfs-tools \
		inputattach iptables iputils-arping iputils-ping iputils-tracepath isc-dhcp-client kbd linux-base lockfile-progs \
		lshw lsof man-db netcat-openbsd nfs-common pciutils procps psmisc rdate squashfs-tools ssl-cert fuse3 systemd-resolved
	sed -i 's/^UID_MIN.*/UID_MIN\t\t\t  502/g' $(R)/etc/login.defs 2>/dev/null || true
	sed -i 's/^GID_MIN.*/GID_MIN\t\t\t  500/g' $(R)/etc/login.defs 2>/dev/null || true
	for s in nice:nice watchdog:busybox flashcp:flashcp flash_erase:flash_erase flash_eraseall:flash_eraseall nanddump:nanddump nandwrite:nandwrite i2cget:i2cget i2cset:i2cset; do \
		dst="/sbin/$${s%%:*}"; [ "$${s%%:*}" = "nice" ] && dst="/bin/nice"; \
		src="$${s##*:}"; \
		chroot $(R) sh -c "[ ! -e $$dst ] && ln -s \$$(which $$src 2>/dev/null || echo /bin/true) $$dst || true"; \
	done
	umount -l $(R)/dev/pts $(R)/sys $(R)/proc 2>/dev/null || true
	rm -f $(R)/usr/sbin/policy-rc.d
	chroot $(R) apt-get clean 2>/dev/null || true
	rm -rf $(R)/tmp/* $(R)/var/tmp/*

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
	mkdir -p $(R)/etc/apt/trusted.gpg.d $(R)/etc/apt/sources.list.d $(R)/etc/apt/preferences.d $(R)/usr/share/keyrings
	[ -f $(R)/etc/apt/trusted.gpg.d/openmediavault-archive-keyring.gpg ] || \
		(curl -fsSL https://packages.openmediavault.org/public/archive.key | gpg --dearmor --batch --yes -o $(R)/etc/apt/trusted.gpg.d/openmediavault-archive-keyring.gpg 2>/dev/null || true)
	[ -f $(R)/usr/share/keyrings/omvextras.gpg ] || \
		(curl -fsSL https://raw.githubusercontent.com/OpenMediaVault-Plugin-Developers/packages/master/debian/omvextras2030.asc | gpg --dearmor --batch --yes -o $(R)/usr/share/keyrings/omvextras.gpg 2>/dev/null && cp -p $(R)/usr/share/keyrings/omvextras.gpg $(R)/etc/apt/trusted.gpg.d/omvextras.gpg 2>/dev/null || true)
	printf 'deb https://packages.openmediavault.org/public sandworm main\n' > $(R)/etc/apt/sources.list.d/openmediavault.list
	printf 'Package: linux-image-*\nPin: release a=sandworm\nPin-Priority: -1\n' > $(R)/etc/apt/preferences.d/openmediavault-kernel.pref
	printf '#!/bin/sh\nexit 101\n' > $(R)/usr/sbin/policy-rc.d && chmod +x $(R)/usr/sbin/policy-rc.d
	mount -t proc proc $(R)/proc 2>/dev/null || true
	mount -t sysfs sys $(R)/sys 2>/dev/null || true
	mount -t devpts devpts $(R)/dev/pts -o gid=5,mode=620 2>/dev/null || true
	trap 'umount -l $(R)/dev/pts $(R)/sys $(R)/proc 2>/dev/null || true; rm -f $(R)/usr/sbin/policy-rc.d' EXIT
	chroot $(R) dpkg -s openmediavault >/dev/null 2>&1 || { \
		DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get update -qq && \
		DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get install -y --no-install-recommends openmediavault openmediavault-md openmediavault-lvm2; }
	chroot $(R) dpkg -s openmediavault-omvextrasorg >/dev/null 2>&1 || ( \
		curl -fsSL -o $(R)/tmp/omvextras.deb https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master/openmediavault-omvextrasorg_latest_all7.deb 2>/dev/null && \
		DEBIAN_FRONTEND=noninteractive chroot $(R) apt-get install -y --no-install-recommends /tmp/omvextras.deb 2>/dev/null || true; \
		rm -f $(R)/tmp/omvextras.deb )
	chroot $(R) groupadd -g 500 everyone 2>/dev/null || true
	chroot $(R) useradd -g everyone -s /bin/bash -u 501 admin 2>/dev/null || true
	chroot $(R) usermod -a -G adm,dialout,fax,cdrom,floppy,tape,audio,dip,video,plugdev,sudo,users,netdev admin 2>/dev/null || true
	for g in ssh _ssh fuse games openmediavault-admin; do chroot $(R) grep -q "^$$g:" /etc/group && chroot $(R) usermod -a -G $$g admin 2>/dev/null || true; done
	chroot $(R) grep -q "^_ssh:" /etc/group && chroot $(R) usermod -a -G _ssh root 2>/dev/null || true
	mkdir -p $(R)/home/admin && chroot $(R) chown admin:everyone /home/admin 2>/dev/null || true
	echo "admin ALL=(ALL) NOPASSWD: ALL" > $(R)/etc/sudoers.d/admin && chmod 0440 $(R)/etc/sudoers.d/admin
	chroot $(R) useradd -g everyone -s /usr/sbin/nologin -u 502 pc-guest 2>/dev/null || true
	chroot $(R) useradd -g everyone -s /usr/sbin/nologin -u 503 anonymous-ftp 2>/dev/null || true
	echo 'root:$(DEFHASH)' | chroot $(R) chpasswd -e 2>/dev/null || true
	echo 'admin:$(DEFHASH)' | chroot $(R) chpasswd -e 2>/dev/null || true
	sed -i -e 's/session required pam_loginuid.so/session optional pam_loginuid.so/' \
	       -e 's/#*PermitRootLogin.*/PermitRootLogin yes/' \
	       -e 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' $(R)/etc/ssh/sshd_config $(R)/etc/pam.d/sshd 2>/dev/null || true
	sed -i 's|^auth.*pam_faillock.so|#&|' $(R)/etc/pam.d/openmediavault* 2>/dev/null || true
	[ -f $(R)/etc/php/8.2/fpm/pool.d/openmediavault-webgui.conf ] && sed -i 's/pm.max_children = .*/pm.max_children = 4/' $(R)/etc/php/8.2/fpm/pool.d/openmediavault-webgui.conf 2>/dev/null || true
	for f in $(R)/var/www/openmediavault/main.*.js ; do [ -f "$$f" ] && sed -i 's/defaultTo(Be,500)/defaultTo(Be,2500)/g' "$$f" 2>/dev/null || true; done
	mkdir -p $(R)/usr/share/openmediavault/initsystem.disabled
	for s in 60rootfs 65mdadm 90sysctl 99rrd; do [ -e $(R)/usr/share/openmediavault/initsystem/$$s ] && mv $(R)/usr/share/openmediavault/initsystem/$$s $(R)/usr/share/openmediavault/initsystem.disabled/ 2>/dev/null || true; done
	rm -f $(R)/usr/share/openmediavault/mkconf/sysctl.d/nonrot 2>/dev/null || true
	[ -e $(R)/usr/share/openmediavault/initsystem/40interfaces ] && sed -i 's/eth|wlan/eth|egiga|wlan/g' $(R)/usr/share/openmediavault/initsystem/40interfaces 2>/dev/null || true
	[ -e $(R)/usr/share/php/openmediavault/system/user.inc ] && sed -i 's/"UID_MIN", 1000/"UID_MIN", 502/g' $(R)/usr/share/php/openmediavault/system/user.inc 2>/dev/null || true
	[ -e $(R)/usr/share/php/openmediavault/system/group.inc ] && sed -i 's/"GID_MIN", 1000/"GID_MIN", 500/g' $(R)/usr/share/php/openmediavault/system/group.inc 2>/dev/null || true
	[ -e $(R)/usr/share/php/openmediavault/system/net/networkinterfacebackend/ethernet.inc ] && sed -i 's/eth|venet/eth|egiga|venet/g' $(R)/usr/share/php/openmediavault/system/net/networkinterfacebackend/ethernet.inc 2>/dev/null || true
	sed -i 's|OMV_MOUNT_DIR="/srv"|OMV_MOUNT_DIR="/media"|g' $(R)/etc/default/openmediavault 2>/dev/null || true
	sed -i 's/^" let g:skip_defaults_vim = 1/let g:skip_defaults_vim = 1/g' $(R)/etc/vim/vimrc 2>/dev/null || true
	sed -i 's/NEED_IDMAPD=.*/NEED_IDMAPD=no/g' $(R)/etc/default/nfs-common 2>/dev/null || true
	sed -i 's/RSYNC_ENABLE=.*/RSYNC_ENABLE=true/g' $(R)/etc/default/rsync 2>/dev/null || true
	printf '#!/bin/sh\nexit 0\n' > $(R)/sbin/hotplug && chmod +x $(R)/sbin/hotplug
	chroot $(R) systemctl enable ssh 2>/dev/null || true
	chroot $(R) systemctl disable quota quotaon systemd-quotacheck openmediavault-beep-down openmediavault-beep-up 2>/dev/null || true
	umount -l $(R)/dev/pts $(R)/sys $(R)/proc 2>/dev/null || true
	rm -f $(R)/usr/sbin/policy-rc.d
	chroot $(R) apt-get clean 2>/dev/null || true
	rm -f $(R)/root/qemu_*.core 2>/dev/null || true
	rm -rf $(R)/tmp/* $(R)/var/tmp/*
	chroot $(R) dpkg -s openmediavault >/dev/null
endif

kernel:
	@echo "=== [Stage 4] Deploying Linux 6.12 Kernel & Overlay ==="
	mkdir -p $(BOOTDIR) $(R)/usr/local/bin
	if [ -f kernel/$(KERNEL_ZIP) ]; then \
		TMP=$$(mktemp -d $(R)/tmp/kdeb.XXXX); \
		REL="/tmp/$$(basename $$TMP)"; \
		unzip -qo kernel/$(KERNEL_ZIP) -d "$$TMP"; \
		[ -f "$$TMP/uImage" ] && cp -p "$$TMP/uImage" $(BOOTDIR)/ && cp -p "$$TMP/uImage" kernel/ 2>/dev/null || true; \
		find "$$TMP" -name "*.dtb" -exec cp -p {} $(BOOTDIR)/ \;; \
		chroot $(R) sh -c "dpkg -i --force-depends $$REL/*.deb 2>/dev/null || true"; \
		rm -rf "$$TMP"; \
	fi
	for z in archives/linux-bsp-*.zip; do \
		[ -f "$$z" ] || continue; \
		TMP=$$(mktemp -d $(R)/tmp/bsp.XXXX); \
		REL="/tmp/$$(basename $$TMP)"; \
		unzip -qo "$$z" -d "$$TMP"; \
		chroot $(R) sh -c "dpkg -i --force-depends $$REL/*.deb 2>/dev/null || true"; \
		rm -rf "$$TMP"; \
	done
	for f in archives/*-init-scripts*.tar.gz; do [ -f "$$f" ] && tar xzf "$$f" -C $(R)/ 2>/dev/null || true; done
	find $(R)/usr/lib/linux-image-* -name "*.dtb" -exec cp -p {} $(BOOTDIR)/ \; 2>/dev/null || true
	[ ! -e $(BOOTDIR)/uImage ] && cp -p $(BOOTDIR)/vmlinuz-* $(BOOTDIR)/uImage 2>/dev/null || true
	[ -e $(BOOTDIR)/uImage ] && cp -p $(BOOTDIR)/uImage kernel/ 2>/dev/null || true
	cp -a overlay/* $(R)/ 2>/dev/null || true
	chmod +x $(R)/usr/local/bin/* $(R)/debinit.sh 2>/dev/null || true

image: diskimage
diskimage:
	@echo "=== [Stage 5] Generating Disk Image ==="
	mkdir -p images mnt_tmp
	chmod +x $(R)/usr/local/bin/* $(R)/debinit.sh 2>/dev/null || true
	rm -f $(R)/root/qemu_*.core 2>/dev/null || true
	rm -rf $(R)/tmp/* $(R)/var/tmp/*
	chroot $(R) apt-get clean 2>/dev/null || true
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
	find $(R)/usr/lib/linux-image-* -name "*.dtb" -exec cp -p {} $(BOOTDIR)/ \; 2>/dev/null || true
	[ ! -e $(BOOTDIR)/uImage ] && (cp -p kernel/uImage $(BOOTDIR)/ 2>/dev/null || cp -p $(BOOTDIR)/vmlinuz-* $(BOOTDIR)/uImage 2>/dev/null || true)
	rsync -aHAX --exclude='/boot/*' --exclude='/mnt_tmp' --exclude='/images' $(R)/ mnt_tmp/
	rsync -rtLv --modify-window=1 $(BOOTDIR)/ mnt_tmp/boot/
	grep -q "TC_ROOT" mnt_tmp/etc/fstab || echo 'LABEL=TC_ROOT / ext4 defaults,noatime 0 1' >> mnt_tmp/etc/fstab
	grep -q "TC_BOOT" mnt_tmp/etc/fstab || echo 'LABEL=TC_BOOT /boot vfat defaults,noatime 0 0' >> mnt_tmp/etc/fstab
	sync && umount mnt_tmp/boot mnt_tmp && rm -rf mnt_tmp
	losetup -d "$$BDEV" "$$RDEV"
	zstd -$(ZSTD_LEVEL) -f --rm "$$IMG"
	chown $$(stat -c '%u:%g' images 2>/dev/null || echo 1000:1000) "$${IMG}.zst" 2>/dev/null || true
	echo "Generated: $${IMG}.zst ($$(ls -lh "$${IMG}.zst" | awk '{print $$5}'))"

endif

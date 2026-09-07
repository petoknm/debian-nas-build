#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:-armhf}"
OUTPUT_DEB="${2:-packages/php-pam_2.2.5-1+deb13u1_armhf.deb}"
FORCE="${FORCE:-0}"

if [ "${FORCE}" != "1" ] && [ -f "${OUTPUT_DEB}" ]; then
	echo "Package ${OUTPUT_DEB} already exists. Skipping build (use FORCE=1 to rebuild)."
	exit 0
fi

if [ ! -d "${ROOTFS}/bin" ] && [ ! -d "${ROOTFS}/usr/bin" ]; then
	echo "ERROR: Target rootfs '${ROOTFS}' does not exist or has not been bootstrapped."
	exit 1
fi

mkdir -p "$(dirname "${OUTPUT_DEB}")"

echo "=== Building standalone armhf php-pam via QEMU ==="

if [ ! -f "${ROOTFS}/usr/bin/qemu-arm-static" ] && [ -f "/usr/bin/qemu-arm-static" ]; then
	cp -p /usr/bin/qemu-arm-static "${ROOTFS}/usr/bin/"
fi

mount -t proc proc "${ROOTFS}/proc" 2>/dev/null || true
mount -t sysfs sys "${ROOTFS}/sys" 2>/dev/null || true
mount -t devpts devpts "${ROOTFS}/dev/pts" -o gid=5,mode=620 2>/dev/null || true
printf '#!/bin/sh\nexit 101\n' > "${ROOTFS}/usr/sbin/policy-rc.d" && chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"

cleanup() {
	rm -f "${ROOTFS}/usr/sbin/policy-rc.d"
	umount -l "${ROOTFS}/dev/pts" 2>/dev/null || true
	umount -l "${ROOTFS}/sys" 2>/dev/null || true
	umount -l "${ROOTFS}/proc" 2>/dev/null || true
}
trap cleanup EXIT

DEBIAN_FRONTEND=noninteractive chroot "${ROOTFS}" apt-get update -qq
DEBIAN_FRONTEND=noninteractive chroot "${ROOTFS}" apt-get install -y --no-install-recommends \
	php-dev libpam0g-dev make ca-certificates wget

chroot "${ROOTFS}" bash -c '
	mkdir -p /tmp/php-pam-build && cd /tmp/php-pam-build
	rm -rf pam-2.2.5
	wget -q -c https://packages.openmediavault.org/public/pool/main/p/php-pam/php-pam_2.2.5.orig.tar.gz
	tar -xzf php-pam_2.2.5.orig.tar.gz
	cd pam-2.2.5
	phpize
	./configure
	make -j$(nproc 2>/dev/null || echo 2)
'

PHP_API=$(chroot "${ROOTFS}" php-config --phpapi 2>/dev/null || echo "20240924")
PHP_VER=$(chroot "${ROOTFS}" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.4")

STAGE_DIR="$(mktemp -d /tmp/php-pam-stage.XXXXXX)"
mkdir -p "${STAGE_DIR}/DEBIAN"
mkdir -p "${STAGE_DIR}/etc/php/${PHP_VER}/mods-available"
mkdir -p "${STAGE_DIR}/usr/lib/php/${PHP_API}"

echo "extension=pam.so" > "${STAGE_DIR}/etc/php/${PHP_VER}/mods-available/pam.ini"
cp "${ROOTFS}/tmp/php-pam-build/pam-2.2.5/modules/pam.so" "${STAGE_DIR}/usr/lib/php/${PHP_API}/"

cat << 'CONTROL_EOF' > "${STAGE_DIR}/DEBIAN/control"
Package: php-pam
Version: 2.2.5-1+deb13u1
Architecture: armhf
Maintainer: Volker Theile <volker.theile@openmediavault.org>
Installed-Size: 91
Depends: phpapi-20240924
Section: web
Priority: optional
Description: pam module for PHP
 PAM integration
 .
 This extension provides PAM (Pluggable Authentication Modules)
 integration.
CONTROL_EOF

cat << 'POSTINST_EOF' > "${STAGE_DIR}/DEBIAN/postinst"
#!/bin/sh
set -e
[ "$1" = "configure" ] && phpenmod pam 2>/dev/null || true
exit 0
POSTINST_EOF
chmod 755 "${STAGE_DIR}/DEBIAN/postinst"

dpkg-deb --build "${STAGE_DIR}" "${OUTPUT_DEB}"
rm -rf "${STAGE_DIR}"
rm -rf "${ROOTFS}/tmp/php-pam-build"

echo "=== Successfully built ${OUTPUT_DEB} ==="

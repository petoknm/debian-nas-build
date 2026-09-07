#!/usr/bin/env bash
# ==============================================================================
# build-salt-deb.sh - Build standalone 32-bit salt-minion .deb for armhf
# ==============================================================================
set -euo pipefail

ROOTFS="${1:-armhf}"
OUTPUT_DEB="${2:-packages/salt-minion_3008.1-1_armhf.deb}"
SALT_VER="${3:-3008.1}"
PKG_VER="${SALT_VER}-1"
FORCE="${FORCE:-0}"

if [ "${FORCE}" != "1" ] && [ -f "${OUTPUT_DEB}" ]; then
	echo "Package ${OUTPUT_DEB} already exists. Skipping build (use FORCE=1 to rebuild)."
	exit 0
fi

if [ ! -d "${ROOTFS}/bin" ] && [ ! -d "${ROOTFS}/usr/bin" ]; then
	echo "ERROR: Target rootfs '${ROOTFS}' does not exist or has not been bootstrapped."
	echo "Run 'make bootstrap' first."
	exit 1
fi

mkdir -p "$(dirname "${OUTPUT_DEB}")"

echo "=== Building standalone armhf salt-minion ${SALT_VER} via QEMU ==="

# Ensure qemu-arm-static is present in the chroot
if [ ! -f "${ROOTFS}/usr/bin/qemu-arm-static" ]; then
	if [ -f "/usr/bin/qemu-arm-static" ]; then
		cp -p /usr/bin/qemu-arm-static "${ROOTFS}/usr/bin/"
	fi
fi

# Mount pseudo filesystems
mount -t proc proc "${ROOTFS}/proc" 2>/dev/null || true
mount -t sysfs sys "${ROOTFS}/sys" 2>/dev/null || true
mount -t devpts devpts "${ROOTFS}/dev/pts" -o gid=5,mode=620 2>/dev/null || true
printf '#!/bin/sh\nexit 101\n' > "${ROOTFS}/usr/sbin/policy-rc.d" && chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"

cleanup() {
	echo "Cleaning up mounts and temporary policies..."
	rm -f "${ROOTFS}/usr/sbin/policy-rc.d"
	umount -l "${ROOTFS}/dev/pts" 2>/dev/null || true
	umount -l "${ROOTFS}/sys" 2>/dev/null || true
	umount -l "${ROOTFS}/proc" 2>/dev/null || true
}
trap cleanup EXIT

# 0. Fix any pre-existing rootfs library/dpkg inconsistencies:
# Remove non-ELF data files mistakenly placed in ldconfig library search paths
rm -f "${ROOTFS}/usr/lib/libzy.so" "${ROOTFS}/usr/lib/arm-linux-gnueabihf/libzy.so" 2>/dev/null || true

# Neutralize linux-setup-nas5xx if left half-configured by kernel package extraction
if [ -f "${ROOTFS}/var/lib/dpkg/info/linux-setup-nas5xx.postinst" ]; then
	printf '#!/bin/sh\nexit 0\n' > "${ROOTFS}/var/lib/dpkg/info/linux-setup-nas5xx.postinst"
fi
chroot "${ROOTFS}" dpkg --configure -a 2>/dev/null || true

# Install build dependencies in chroot
echo "[1/4] Installing Python and compiler dependencies in armhf rootfs..."
DEBIAN_FRONTEND=noninteractive chroot "${ROOTFS}" apt-get update -qq
DEBIAN_FRONTEND=noninteractive chroot "${ROOTFS}" apt-get install -y --no-install-recommends \
	python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev

# Create native virtual environment at destination path
echo "[2/4] Creating native virtual environment at /opt/saltstack/salt..."
mkdir -p "${ROOTFS}/opt/saltstack"
chroot "${ROOTFS}" python3 -m venv --system-site-packages /opt/saltstack/salt

echo "[3/4] Compiling and installing SaltStack ${SALT_VER} via pip (native 32-bit)..."
chroot "${ROOTFS}" /opt/saltstack/salt/bin/pip install --upgrade pip setuptools wheel
chroot "${ROOTFS}" /opt/saltstack/salt/bin/pip install "salt==${SALT_VER}"
chroot "${ROOTFS}" /opt/saltstack/salt/bin/pip cache purge 2>/dev/null || true
rm -rf "${ROOTFS}/root/.cache" 2>/dev/null || true

# Assemble package staging directory
echo "[4/4] Packaging into ${OUTPUT_DEB}..."
STAGE_DIR="$(mktemp -d /tmp/salt-deb-stage.XXXXXX)"
mkdir -p "${STAGE_DIR}/DEBIAN" "${STAGE_DIR}/opt/saltstack" "${STAGE_DIR}/usr/bin" "${STAGE_DIR}/etc/salt"

# Copy the built /opt/saltstack/salt tree
cp -a "${ROOTFS}/opt/saltstack/salt" "${STAGE_DIR}/opt/saltstack/"

# Provide CLI symlinks
ln -sf /opt/saltstack/salt/bin/salt-call "${STAGE_DIR}/usr/bin/salt-call"
ln -sf /opt/saltstack/salt/bin/salt-minion "${STAGE_DIR}/usr/bin/salt-minion"

# Generate DEBIAN/control
cat << CONTROL_EOF > "${STAGE_DIR}/DEBIAN/control"
Package: salt-minion
Version: ${PKG_VER}
Section: admin
Priority: optional
Architecture: armhf
Maintainer: debian-nas-build
Depends: python3, python3-venv
Provides: salt-minion, salt-common
Replaces: salt-common, salt-minion
Conflicts: salt-common
Description: Standalone 32-bit SaltStack onedir bundle for armhf
 This package provides SaltStack in /opt/saltstack/salt for 32-bit
 ARM architectures (armhf) to enable OpenMediaVault support.
CONTROL_EOF

# Build .deb package
dpkg-deb --build "${STAGE_DIR}" "${OUTPUT_DEB}"
rm -rf "${STAGE_DIR}"

# Also generate openmediavault-salt companion deb package
OMV_SALT_DEB="$(dirname "${OUTPUT_DEB}")/openmediavault-salt_8.1.0_all.deb"
echo "Generating ${OMV_SALT_DEB}..."
OMV_STAGE_DIR="$(mktemp -d /tmp/omv-salt-stage.XXXXXX)"
mkdir -p "${OMV_STAGE_DIR}/DEBIAN" "${OMV_STAGE_DIR}/opt/saltstack/salt/extras-3.14"
cat << OMV_CONTROL_EOF > "${OMV_STAGE_DIR}/DEBIAN/control"
Package: openmediavault-salt
Version: 8.1.0
Section: admin
Priority: optional
Architecture: all
Maintainer: debian-nas-build
Depends: salt-minion (>= 3008.1)
Description: Extra Python packages required by Salt on openmediavault for armhf
OMV_CONTROL_EOF

cat << 'POSTINST_EOF' > "${OMV_STAGE_DIR}/DEBIAN/postinst"
#!/bin/sh
set -e
ln -sfn /usr/lib/python3/dist-packages/openmediavault /opt/saltstack/salt/extras-3.14/openmediavault
exit 0
POSTINST_EOF
chmod 755 "${OMV_STAGE_DIR}/DEBIAN/postinst"

dpkg-deb --build "${OMV_STAGE_DIR}" "${OMV_SALT_DEB}"
rm -rf "${OMV_STAGE_DIR}"

# Purge build compilers to keep armhf rootfs clean
echo "Purging temporary build tools from armhf rootfs..."
DEBIAN_FRONTEND=noninteractive chroot "${ROOTFS}" apt-get purge -y \
	build-essential libffi-dev libssl-dev python3-dev 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive chroot "${ROOTFS}" apt-get autoremove -y --purge 2>/dev/null || true
chroot "${ROOTFS}" apt-get clean 2>/dev/null || true
rm -rf "${ROOTFS}/tmp"/* "${ROOTFS}/var/tmp"/* 2>/dev/null || true

echo "=== Successfully built ${OUTPUT_DEB} ==="

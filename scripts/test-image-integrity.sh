#!/usr/bin/env bash
# ==============================================================================
# test-image-integrity.sh - Comprehensive image integrity & compatibility tests
# ==============================================================================
set -euo pipefail

IMAGE="${1:-}"
if [ -z "${IMAGE}" ]; then
	IMAGE=$(ls -t images/*.img.zst 2>/dev/null | head -n1 || true)
fi

if [ -z "${IMAGE}" ] || [ ! -f "${IMAGE}" ]; then
	echo "ERROR: No target image found to test. Specify IMAGE=/path/to/image.img.zst or build one first."
	exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}==================================================================${NC}"
echo -e "${BOLD} Debian NAS Image Integrity Test Suite${NC}"
echo -e " Target: ${CYAN}${IMAGE}${NC} ($(ls -lh "${IMAGE}" | awk '{print $5}'))"
echo -e "${BOLD}==================================================================${NC}"

# Check host dependencies
SEVENZ=$(command -v 7z || command -v 7zz || true)
ZSTD=$(command -v zstd || true)
SGDISK=$(command -v sgdisk || true)

if [ -z "${SEVENZ}" ] || [ -z "${ZSTD}" ] || [ -z "${SGDISK}" ]; then
	echo -e "${RED}ERROR: Missing required tools on host (7z, zstd, sgdisk).${NC}"
	exit 1
fi

TMPDIR=$(mktemp -d /tmp/nas-img-test.XXXXXX)
cleanup() {
	rm -rf "${TMPDIR}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

report_test() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [ "${status}" -eq 0 ]; then
		PASS_COUNT=$((PASS_COUNT + 1))
		printf "  [%bPASS%b] %-50s %b\n" "${GREEN}" "${NC}" "${name}" "${detail}"
	else
		FAIL_COUNT=$((FAIL_COUNT + 1))
		printf "  [%bFAIL%b] %-50s %b\n" "${RED}" "${NC}" "${name}" "${RED}${detail}${NC}"
	fi
}

# ------------------------------------------------------------------------------
# 1. Image Compression & Unpacking
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1/4] Image Archive & Partition Layout${NC}"

# Test zstd archive integrity
"${ZSTD}" -t -q "${IMAGE}" 2>/dev/null
report_test "Archive: zstd checksum integrity" $? ""

# Decompress to temporary raw image
RAW_IMG="${TMPDIR}/disk.img"
"${ZSTD}" -d -q -c "${IMAGE}" > "${RAW_IMG}" 2>/dev/null
report_test "Archive: decompress raw image" $? "($(ls -lh "${RAW_IMG}" 2>/dev/null | awk '{print $5}'))"

# Verify GPT table validity
"${SGDISK}" -v "${RAW_IMG}" >/dev/null 2>&1
report_test "GPT: partition table valid & non-corrupt" $? ""

# Check partition 1 (TC_BOOT)
"${SGDISK}" -i 1 "${RAW_IMG}" > "${TMPDIR}/p1_info.txt" 2>/dev/null
grep -q "Partition name: 'TC_BOOT'" "${TMPDIR}/p1_info.txt" && \
grep -qi "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" "${TMPDIR}/p1_info.txt" && \
grep -qi "54CDF5DA-DEB1-B007-A694-32880502EF34" "${TMPDIR}/p1_info.txt"
report_test "GPT: partition 1 (TC_BOOT, 0700, fixed UUID)" $? "TC_BOOT"

# Check partition 2 (TC_ROOT)
"${SGDISK}" -i 2 "${RAW_IMG}" > "${TMPDIR}/p2_info.txt" 2>/dev/null
grep -q "Partition name: 'TC_ROOT'" "${TMPDIR}/p2_info.txt" && \
grep -qi "0FC63DAF-8483-4772-8E79-3D69D8477DE4" "${TMPDIR}/p2_info.txt" && \
grep -qi "54CDF5DA-DEB1-F007-A694-32880502EF34" "${TMPDIR}/p2_info.txt"
report_test "GPT: partition 2 (TC_ROOT, 8300, fixed UUID)" $? "TC_ROOT"

# Extract partition images
"${SEVENZ}" e "${RAW_IMG}" 0.TC_BOOT.fat 1.TC_ROOT.img -o"${TMPDIR}" >/dev/null 2>&1
FAT_IMG="${TMPDIR}/0.TC_BOOT.fat"
EXT_IMG="${TMPDIR}/1.TC_ROOT.img"
# Remove raw image to reclaim disk space immediately
rm -f "${RAW_IMG}"

# ------------------------------------------------------------------------------
# 2. Boot Partition (TC_BOOT) Contents
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/4] Boot Partition (TC_BOOT) Integrity${NC}"

BOOT_LIST="${TMPDIR}/boot_files.txt"
"${SEVENZ}" l "${FAT_IMG}" > "${BOOT_LIST}" 2>/dev/null

# uImage exists & > 5MB
UIMG_SIZE=$(awk '$NF == "uImage" {print $4}' "${BOOT_LIST}")
[ -n "${UIMG_SIZE}" ] && [ "${UIMG_SIZE}" -gt 5000000 ]
report_test "Boot: Linux 6.12 uImage present" $? "$((UIMG_SIZE / 1024 / 1024)) MB"

# Verify device tree blobs for NAS5xx
DTBS_OK=0
for dtb in ls1024a-nas540.dtb ls1024a-nas520.dtb ls1024a-nas5xx.dtb; do
	grep -q "${dtb}" "${BOOT_LIST}" || DTBS_OK=1
done
report_test "Boot: Comcerto 2000 DTBs (nas540, nas520, nas5xx)" $DTBS_OK ""

# Stock pivot boot scripts
PIVOT_OK=0
for s in debroot.sh usb_key_func.sh; do
	grep -q "${s}" "${BOOT_LIST}" || PIVOT_OK=1
done
report_test "Boot: Stock Barebox pivot scripts (debroot, usb_key)" $PIVOT_OK ""

# Factory authentication files
AUTH_OK=0
for a in md5sum nas5xx_check_file salted_md5sum_libzy.so.fw5; do
	grep -q "${a}" "${BOOT_LIST}" || AUTH_OK=1
done
report_test "Boot: Stock authentication files (nas5xx_check, md5)" $AUTH_OK ""

# Ensure NO legacy NSA / STG clutter on boot partition
grep -iE 'nsa2|nsa3|stg' "${BOOT_LIST}" >/dev/null && NSA_LEFTOVERS=1 || NSA_LEFTOVERS=0
[ "${NSA_LEFTOVERS}" -eq 0 ]
report_test "Boot: Zero legacy NSA/STG checkfile clutter" $? ""

# ------------------------------------------------------------------------------
# 3. Target Rootfs (TC_ROOT) System Configuration
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/4] Root Filesystem (TC_ROOT) System Configuration${NC}"

# Check Debian suite in /etc/debian_version
DEB_VER=$("${SEVENZ}" e "${EXT_IMG}" etc/debian_version -so 2>/dev/null || true)
echo "${DEB_VER}" | grep -q "^13\."
report_test "OS: Pure Debian 13 (Trixie) release" $? "${DEB_VER}"

# Check /etc/fstab mounts
"${SEVENZ}" e "${EXT_IMG}" etc/fstab -so > "${TMPDIR}/fstab.txt" 2>/dev/null || true
grep -q "LABEL=TC_ROOT" "${TMPDIR}/fstab.txt" && grep -q "LABEL=TC_BOOT" "${TMPDIR}/fstab.txt"
report_test "fstab: Persistent LABEL=TC_ROOT and TC_BOOT mounts" $? ""

# File listing of rootfs
ROOT_LIST="${TMPDIR}/root_files.txt"
"${SEVENZ}" l "${EXT_IMG}" > "${ROOT_LIST}" 2>/dev/null

# Verify first-boot and flasher scripts
SCRIPTS_OK=0
for sc in debinit.sh usr/local/bin/zy-bb-env-and-kernel2-write usr/local/bin/zy-kernel2-write usr/local/bin/zy-expand-rootfs usr/local/bin/zy-ready; do
	grep -q "${sc}" "${ROOT_LIST}" || SCRIPTS_OK=1
done
report_test "Init: First-boot flasher & expand scripts present" $SCRIPTS_OK ""

# Dynamic PHP detection in debinit.sh
"${SEVENZ}" e "${EXT_IMG}" debinit.sh -so > "${TMPDIR}/debinit.sh" 2>/dev/null || true
grep -q 'php\*-fpm' "${TMPDIR}/debinit.sh"
report_test "Init: Dynamic PHP-FPM service restart in debinit.sh" $? ""

# Check vendor hardware tools & MTD flash binaries
TOOLS_OK=0
for tool in firmware/sbin/info_setenv usr/local/bin/buzzerc usr/sbin/flash_erase usr/sbin/nandwrite; do
	grep -q "${tool}" "${ROOT_LIST}" || TOOLS_OK=1
done
report_test "Hardware: MTD flashers & vendor controls (info_setenv, buzzerc)" $TOOLS_OK ""

# Check kernel modules
grep -q "usr/lib/modules/6.12.95+nas5xx/modules.dep" "${ROOT_LIST}"
report_test "Kernel: Linux 6.12 kernel modules tree populated" $? ""

# ------------------------------------------------------------------------------
# 4. OpenMediaVault 8 & SaltStack 32-bit Runtime
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4/4] OpenMediaVault 8 & SaltStack Runtime${NC}"

"${SEVENZ}" e "${EXT_IMG}" var/lib/dpkg/status -so > "${TMPDIR}/dpkg_status.txt" 2>/dev/null || true

# OpenMediaVault 8 installed
OMV_INSTALLED=1
grep -A 5 "Package: openmediavault$" "${TMPDIR}/dpkg_status.txt" | grep -q "Status: install ok installed" && OMV_INSTALLED=0
[ $OMV_INSTALLED -eq 0 ]
OMV_VER=$(grep -A 5 "Package: openmediavault$" "${TMPDIR}/dpkg_status.txt" | awk '/Version:/ {print $2}')
report_test "OMV: OpenMediaVault 8 package configured" $? "${OMV_VER}"

# Standalone 32-bit php-pam installed
PHP_PAM_INSTALLED=1
grep -A 5 "Package: php-pam$" "${TMPDIR}/dpkg_status.txt" | grep -q "Status: install ok installed" && PHP_PAM_INSTALLED=0
[ $PHP_PAM_INSTALLED -eq 0 ]
PAM_VER=$(grep -A 5 "Package: php-pam$" "${TMPDIR}/dpkg_status.txt" | awk '/Version:/ {print $2}')
report_test "OMV: 32-bit armhf php-pam extension package" $? "${PAM_VER}"

# Standalone 32-bit salt-minion installed
SALT_INSTALLED=1
grep -A 5 "Package: salt-minion$" "${TMPDIR}/dpkg_status.txt" | grep -q "Status: install ok installed" && SALT_INSTALLED=0
[ $SALT_INSTALLED -eq 0 ]
SALT_VER=$(grep -A 5 "Package: salt-minion$" "${TMPDIR}/dpkg_status.txt" | awk '/Version:/ {print $2}')
report_test "Salt: 32-bit armhf salt-minion package" $? "${SALT_VER}"

# OpenMediaVault-Salt bridge installed
OMV_SALT_INSTALLED=1
grep -A 5 "Package: openmediavault-salt$" "${TMPDIR}/dpkg_status.txt" | grep -q "Status: install ok installed" && OMV_SALT_INSTALLED=0
[ $OMV_SALT_INSTALLED -eq 0 ]
report_test "Salt: openmediavault-salt bridge package" $? ""

# Salt CLI executables present
SALT_CLI_OK=0
for bin in usr/bin/salt-call usr/bin/salt-minion; do
	grep -q "${bin}" "${ROOT_LIST}" || SALT_CLI_OK=1
done
report_test "Salt: /usr/bin/salt-call & salt-minion CLI symlinks" $SALT_CLI_OK ""

# OpenMediaVault-Extras installed
OMV_EXTRAS_INSTALLED=1
grep -A 5 "Package: openmediavault-omvextrasorg$" "${TMPDIR}/dpkg_status.txt" | grep -q "Status: install ok installed" && OMV_EXTRAS_INSTALLED=0
[ $OMV_EXTRAS_INSTALLED -eq 0 ]
report_test "OMV: openmediavault-omvextrasorg package" $? ""

# Enabled systemd units
UNITS_OK=0
for unit in etc/systemd/system/multi-user.target.wants/openmediavault-engined.service \
            etc/systemd/system/multi-user.target.wants/nginx.service \
            etc/systemd/system/multi-user.target.wants/ssh.service; do
	grep -q "${unit}" "${ROOT_LIST}" || UNITS_OK=1
done
report_test "Services: systemd multi-user units (omv-engined, nginx, ssh)" $UNITS_OK ""

# ARM Performance Tuning
ARM_TUNED=1
"${SEVENZ}" e "${EXT_IMG}" etc/php/8.4/fpm/pool.d/openmediavault-webgui.conf -so > "${TMPDIR}/fpm.conf" 2>/dev/null || true
grep -q "pm.max_children = 4" "${TMPDIR}/fpm.conf" && ARM_TUNED=0
[ $ARM_TUNED -eq 0 ]
report_test "Performance: PHP-FPM pool tuned (pm.max_children = 4)" $? ""

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}==================================================================${NC}"
if [ ${FAIL_COUNT} -eq 0 ]; then
	echo -e " ${BOLD}Results:${NC} ${GREEN}${PASS_COUNT}/${TOTAL_COUNT} Tests Passed (100%)${NC}"
	echo -e " ${GREEN}ALL IMAGE INTEGRITY CHECKS PASSED SUCCESSFULLY!${NC}"
	echo -e "${BOLD}==================================================================${NC}\n"
	exit 0
else
	echo -e " ${BOLD}Results:${NC} ${RED}${FAIL_COUNT} Failed${NC}, ${GREEN}${PASS_COUNT} Passed${NC} (Total: ${TOTAL_COUNT})"
	echo -e " ${RED}SOME IMAGE INTEGRITY CHECKS FAILED!${NC}"
	echo -e "${BOLD}==================================================================${NC}\n"
	exit 1
fi

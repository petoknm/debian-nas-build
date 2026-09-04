#!/usr/bin/env bash
# ==============================================================================
# menuconfig.sh - Interactive Configuration TUI for Debian NAS Build
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

CONFIG_FILE=".config"
CONFIG_DEFAULT=".config.default"

[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}" || { [ -f "${CONFIG_DEFAULT}" ] && source "${CONFIG_DEFAULT}"; }

MODEL="${MODEL:-nas542}"
ENABLE_OMV="${ENABLE_OMV:-true}"
HOSTNAME="${HOSTNAME:-debian-nas}"
ETH0_MODE="${ETH0_MODE:-dhcp}"
ETH0_IP="${ETH0_IP:-192.168.1.100}"
ETH0_NETMASK="${ETH0_NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-192.168.1.1}"
NAMESERVER="${NAMESERVER:-1.1.1.1}"

TUI_BIN="$(command -v whiptail 2>/dev/null || command -v dialog 2>/dev/null || true)"
if [ -z "${TUI_BIN}" ]; then
	CONTAINER="$(command -v docker 2>/dev/null || command -v podman 2>/dev/null || true)"
	if [ -n "${CONTAINER}" ]; then
		echo "Notice: whiptail not found on host, launching inside container..."
		exec "${CONTAINER}" run --rm -it -v "${PWD}":/build -w /build debian-nas-builder ./menuconfig.sh
	fi
	echo "ERROR: Neither 'whiptail' nor 'dialog' was found on host."
	exit 1
fi

while true; do
	CHOICE=$("${TUI_BIN}" --title "Debian NAS Build Configuration" --cancel-button "Exit" --ok-button "Select" \
		--menu "Select a setting to configure:" 16 70 6 \
		"1" "Hardware Model:       [${MODEL}]" \
		"2" "OpenMediaVault 7:     [${ENABLE_OMV}]" \
		"3" "System Hostname:      [${HOSTNAME}]" \
		"4" "Network Mode:         [${ETH0_MODE}]" \
		"5" "Save Configuration & Exit" \
		3>&1 1>&2 2>&3 || true)

	[ -z "${CHOICE}" ] && { echo "Configuration aborted."; exit 0; }

	case "${CHOICE}" in
		1)
			M=$("${TUI_BIN}" --title "Target Hardware Model" --cancel-button "Back" --ok-button "Select" \
				--menu "Select your Zyxel NAS device:" 15 65 7 \
				"nas542"  "Zyxel NAS542 (LS1024A 4-Bay)" \
				"nas540"  "Zyxel NAS540 (LS1024A 4-Bay)" \
				"nas520"  "Zyxel NAS520 (LS1024A 2-Bay)" \
				"nas326"  "Zyxel NAS326 (Armada 380 2-Bay)" \
				"nsa325"  "Zyxel NSA325 (Kirkwood 2-Bay)" \
				"nsa320s" "Zyxel NSA320S (Kirkwood 2-Bay)" \
				"nsa310s" "Zyxel NSA310S (Kirkwood 1-Bay)" \
				3>&1 1>&2 2>&3 || true)
			[ -n "${M}" ] && MODEL="${M}"
			;;
		2)
			if "${TUI_BIN}" --title "OpenMediaVault 7" --yes-button "Enable" --no-button "Disable" \
				--yesno "Include OpenMediaVault 7 (Sandworm)?" 8 55; then
				ENABLE_OMV="true"
			else
				ENABLE_OMV="false"
			fi
			;;
		3)
			H=$("${TUI_BIN}" --title "System Hostname" --inputbox "Enter NAS hostname:" 8 50 "${HOSTNAME}" 3>&1 1>&2 2>&3 || true)
			[ -n "${H}" ] && HOSTNAME="${H}"
			;;
		4)
			N=$("${TUI_BIN}" --title "Network Configuration" --cancel-button "Back" --ok-button "Select" \
				--menu "IP configuration for eth0:" 10 50 2 \
				"dhcp"   "Automatic IP via DHCP" \
				"static" "Manual Static IP Address" \
				3>&1 1>&2 2>&3 || true)
			if [ "${N}" = "dhcp" ]; then
				ETH0_MODE="dhcp"
			elif [ "${N}" = "static" ]; then
				ETH0_MODE="static"
				ETH0_IP=$("${TUI_BIN}" --inputbox "Enter Static IP:" 8 50 "${ETH0_IP}" 3>&1 1>&2 2>&3 || true)
				ETH0_NETMASK=$("${TUI_BIN}" --inputbox "Enter Netmask:" 8 50 "${ETH0_NETMASK}" 3>&1 1>&2 2>&3 || true)
				GATEWAY=$("${TUI_BIN}" --inputbox "Enter Gateway:" 8 50 "${GATEWAY}" 3>&1 1>&2 2>&3 || true)
				NAMESERVER=$("${TUI_BIN}" --inputbox "Enter Primary DNS:" 8 50 "${NAMESERVER}" 3>&1 1>&2 2>&3 || true)
			fi
			;;
		5)
			cat > "${CONFIG_FILE}" << EOF
MODEL="${MODEL}"
ENABLE_OMV="${ENABLE_OMV}"
HOSTNAME="${HOSTNAME}"
ETH0_MODE="${ETH0_MODE}"
ETH0_IP="${ETH0_IP}"
ETH0_NETMASK="${ETH0_NETMASK}"
GATEWAY="${GATEWAY}"
NAMESERVER="${NAMESERVER}"
EOF
			echo "Configuration saved to ${CONFIG_FILE} (Model: ${MODEL}, OMV: ${ENABLE_OMV}, Host: ${HOSTNAME})"
			exit 0
			;;
	esac
done

#!/usr/bin/env bash
# ==============================================================================
# debian-nas-build: Top-Level Build Orchestrator
# ==============================================================================
# Automates prerequisites preparation, container isolation, and Debian/OMV
# image generation for Zyxel NAS hardware.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Defaults
ACTION="batch"
BOARD_MODEL="nas542"
ENABLE_OMV="true"
HOSTNAME_VAL="debian-nas"
CONTAINER_RUNTIME=""
INTERACTIVE=false

USE_SUDO="auto"

DEFAULT_KERNEL_VERSION="6.12.95-20260823"
DEFAULT_KERNEL_ZIP="linux-image-${DEFAULT_KERNEL_VERSION}-nas5xx-armhf.zip"
DEFAULT_KERNEL_URL="https://github.com/scpcom/linux/releases/download/v6.12.95-7018-sbc/${DEFAULT_KERNEL_ZIP}"

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: ./build.sh [COMMAND] [OPTIONS]

Commands:
  full, batch         Run complete build from scratch in batch mode (default)
  image, diskimage    Quick rebuild of USB disk image from existing armhf/ tree
  interactive         Run interactive build with whiptail configuration menus
  prep                Only download/prepare prerequisites (kernel, init-scripts, config)
  shell               Launch an interactive bash shell inside the build container
  clean               Clean temporary build artifacts and mounts

Options:
  --model <name>      Target hardware model (default: nas542)
                      Supported: nas542, nas540, nas520, nas326, nsa325, nsa320s, nsa310s
  --no-omv            Disable OpenMediaVault (build minimal Debian 12 only)
  --hostname <name>   Set system hostname (default: debian-nas)
  --docker            Force using Docker instead of Podman
  --podman            Force using Podman instead of Docker
  --no-sudo           Do not prefix container command with sudo
  -h, --help          Show this help message

Examples:
  ./build.sh                         # Full automated build for NAS542 with OMV 7
  ./build.sh image                   # Fast rebuild of USB .img.gz (~30 seconds)
  ./build.sh full --model nas540     # Full build for NAS540
  ./build.sh shell                   # Drop into container shell for debugging
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        full|batch)
            ACTION="batch"
            shift
            ;;
        image|diskimage)
            ACTION="diskimage"
            shift
            ;;
        interactive)
            ACTION="interactive"
            INTERACTIVE=true
            shift
            ;;
        prep)
            ACTION="prep"
            shift
            ;;
        shell)
            ACTION="shell"
            shift
            ;;
        clean)
            ACTION="clean"
            shift
            ;;
        --model)
            BOARD_MODEL="$2"
            shift 2
            ;;
        --no-omv)
            ENABLE_OMV="false"
            shift
            ;;
        --hostname)
            HOSTNAME_VAL="$2"
            shift 2
            ;;
        --docker)
            CONTAINER_RUNTIME="docker"
            shift
            ;;
        --podman)
            CONTAINER_RUNTIME="podman"
            shift
            ;;
        --no-sudo)
            USE_SUDO="false"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option/command: $1"
            echo "Run './build.sh --help' for usage."
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Detect Container Engine
# ------------------------------------------------------------------------------
detect_container_runtime() {
    if [[ -n "${CONTAINER_RUNTIME}" ]]; then
        if ! command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
            echo "ERROR: Requested container runtime '${CONTAINER_RUNTIME}' is not installed."
            exit 1
        fi
        return
    fi

    if command -v podman >/dev/null 2>&1; then
        CONTAINER_RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    else
        echo "ERROR: Neither 'podman' nor 'docker' was found on your system."
        echo "Please install Podman or Docker to run isolated reproducible builds."
        exit 1
    fi
}

# Determine if sudo is required for container execution with privileged /dev access
get_container_cmd() {
    local cmd=()
    # Loop device setup (/dev/loop*) inside containers requires root
    if [[ "${USE_SUDO}" == "true" ]] || ([[ "${USE_SUDO}" == "auto" ]] && [[ $EUID -ne 0 ]]); then
        cmd+=("sudo")
    fi
    cmd+=("${CONTAINER_RUNTIME}")
    echo "${cmd[@]}"
}

# ------------------------------------------------------------------------------
# Prerequisites Preparation
# ------------------------------------------------------------------------------
prepare_prerequisites() {
    echo "=== [1/3] Preparing Bookworm init scripts ==="
    mkdir -p archives
    if [[ ! -e archives/debian-bookworm-init-scripts.tar.gz ]]; then
        if [[ -e archives/debian-bullseye-init-scripts.tar.gz ]]; then
            echo "Linking archives/debian-bookworm-init-scripts.tar.gz -> debian-bullseye-init-scripts.tar.gz"
            ln -sf debian-bullseye-init-scripts.tar.gz archives/debian-bookworm-init-scripts.tar.gz
        else
            echo "WARNING: archives/debian-bullseye-init-scripts.tar.gz missing!"
        fi
    else
        echo "Bookworm init scripts archive present."
    fi

    echo "=== [2/3] Checking Linux kernel package ==="
    mkdir -p kernel
    local found_kernel
    found_kernel=$(ls kernel/linux-image-*-armhf.zip 2>/dev/null | head -n1 || true)

    if [[ -z "${found_kernel}" ]]; then
        echo "No kernel zip found in kernel/. Downloading tested Linux 6.12 NAS5xx kernel..."
        if command -v wget >/dev/null 2>&1; then
            wget -q --show-progress -O "kernel/${DEFAULT_KERNEL_ZIP}" "${DEFAULT_KERNEL_URL}"
        elif command -v curl >/dev/null 2>&1; then
            curl -L --progress-bar -o "kernel/${DEFAULT_KERNEL_ZIP}" "${DEFAULT_KERNEL_URL}"
        else
            echo "ERROR: Neither 'wget' nor 'curl' is installed on host to download kernel."
            echo "Please download ${DEFAULT_KERNEL_URL} into the kernel/ directory."
            exit 1
        fi
        echo "Kernel download complete: kernel/${DEFAULT_KERNEL_ZIP}"
    else
        echo "Using kernel package: ${found_kernel}"
    fi

    echo "=== [3/3] Generating build configuration ==="
    mkdir -p etc
    local fw_url=""
    case "${BOARD_MODEL}" in
        nas542) fw_url="ftp://ftp.zyxel.com/NAS542/firmware/NAS542_V5.21(ABAG.0)C0.zip" ;;
        nas540) fw_url="ftp://ftp.zyxel.com/NAS540/firmware/NAS540_V5.21(AATB.0)C0.zip" ;;
        nas520) fw_url="ftp://ftp.zyxel.com/NAS520/firmware/NAS520_V5.21(AASZ.0)C0.zip" ;;
        nas326) fw_url="ftp://ftp.zyxel.com/NAS326/firmware/NAS326_V5.21(AAZF.0)C0.zip" ;;
        nsa325) fw_url="ftp://ftp.zyxel.com/NSA325/firmware/NSA325_V4.81(AAAJ.0)C0.zip" ;;
        nsa320s) fw_url="ftp://ftp.zyxel.com/NSA320S/firmware/NSA320S_V4.75(AANV.1)C0.zip" ;;
        nsa310s) fw_url="ftp://ftp.zyxel.com/NSA310S/firmware/NSA310S_V4.75(AALH.1)C0.zip" ;;
        *) fw_url="" ;;
    esac

    # Only create if missing, or update if explicitly specified on command line
    if [[ ! -f etc/debian-build.conf ]]; then
        cat > etc/debian-build.conf << EOF
boardModel=${BOARD_MODEL}
FWGETURL="${fw_url}"
FWUSEVER="newer"
fanSpeed=keep
firstUser=share
imageMdMount=false
imageOmv=${ENABLE_OMV}
imageOmvInit=${ENABLE_OMV}
imageHostname=${HOSTNAME_VAL}
imageEth0Ip=dhcp
imageEth0Mask=255.255.255.0
imageEth1Ip=dhcp
imageEth1Mask=255.255.255.0
imageRouter=
imageDNS=
installRecommends=1
installISCSITarget=0
installMailServer=1
installNFSServer=1
installNTPServer=0
installSMBServer=1
installMiscServer=1
installWifi=0
installIpmitool=0
installSmartctl=1
EOF
        echo "Configuration written to etc/debian-build.conf (Model: ${BOARD_MODEL}, OMV: ${ENABLE_OMV})"
    else
        echo "Using existing etc/debian-build.conf"
    fi
}

# ------------------------------------------------------------------------------
# Clean Action
# ------------------------------------------------------------------------------
do_clean() {
    echo "Cleaning temporary build artifacts and images..."
    rm -rf images/*
    rm -f armhf/tmp/*
    echo "Clean complete."
    exit 0
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
if [[ "${ACTION}" == "clean" ]]; then
    do_clean
fi

prepare_prerequisites

if [[ "${ACTION}" == "prep" ]]; then
    echo "Prerequisites prepared successfully. You are ready to build."
    exit 0
fi

detect_container_runtime
CONTAINER_CMD=$(get_container_cmd)

echo "=== Launching build environment via ${CONTAINER_RUNTIME} ==="

CONTAINER_PACKAGES="fdisk dosfstools e2fsprogs gdisk rsync binutils parted unzip debootstrap qemu-user-static binfmt-support whiptail patch wget gnupg ca-certificates python3-minimal"

case "${ACTION}" in
    shell)
        echo "Dropping into interactive container shell. /build contains your repository."
        ${CONTAINER_CMD} run --rm -it --privileged \
            -v /dev:/dev \
            -v "${PWD}":/build \
            -w /build \
            debian:bookworm \
            bash -c "apt-get update && apt-get install -y ${CONTAINER_PACKAGES} && exec bash"
        ;;
    diskimage)
        echo "Rebuilding disk image from armhf/ directory..."
        ${CONTAINER_CMD} run --rm -it --privileged \
            -v /dev:/dev \
            -v "${PWD}":/build \
            -w /build \
            debian:bookworm \
            bash -c "apt-get update && apt-get install -y ${CONTAINER_PACKAGES} && ./build-debian.sh diskimage"
        ;;
    interactive)
        echo "Starting interactive build menus..."
        ${CONTAINER_CMD} run --rm -it --privileged \
            -v /dev:/dev \
            -v "${PWD}":/build \
            -w /build \
            debian:bookworm \
            bash -c "apt-get update && apt-get install -y ${CONTAINER_PACKAGES} && ./build-debian.sh"
        ;;
    batch|full)
        echo "Starting automated full build in batch mode..."
        ${CONTAINER_CMD} run --rm -it --privileged \
            -v /dev:/dev \
            -v "${PWD}":/build \
            -w /build \
            debian:bookworm \
            bash -c "apt-get update && apt-get install -y ${CONTAINER_PACKAGES} && ./build-debian.sh batch"
        ;;
esac

echo ""
echo "=== Build finished ==="
if compgen -G "images/*.img.gz" > /dev/null; then
    echo "Generated disk image(s):"
    ls -lh images/*.img.gz
fi

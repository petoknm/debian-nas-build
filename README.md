# Debian NAS Build for Zyxel Devices

This project builds customized, bootable **Debian 12 (Bookworm)** disk images with **OpenMediaVault 7 (Sandworm)** for Zyxel NAS hardware, featuring modern Linux kernels (6.12.x) and native systemd support.

---

## Supported Hardware

- **Zyxel NAS542, NAS540, NAS520** (Mindspeed Comcerto 2000 / LS1024A, ARMv7 Cortex-A9 dual-core)
- **Zyxel NAS326** (Marvell Armada 380)
- **Zyxel NSA310, NSA310S, NSA320, NSA320S, NSA325** (Marvell Kirkwood)

---

## Key Features

- **Modern Linux Kernel (6.12.x)**: Replaces the deprecated factory Linux 3.2 kernel while preserving factory recovery partitions.
- **OpenMediaVault 7 (Sandworm)**: Pre-configured with PHP-FPM 8.2, Nginx, engine daemon, and PAM authentication.
- **Fully Automated First-Boot Kernel Flashing**: Boots via USB, automatically flashes the 6.12 kernel to the alternate NAND partition, updates Barebox bootloader parameters, beeps the buzzer, and reboots directly into modern Linux.
- **Dual-Slot NAND Safety**: Dynamically detects whether the NAS is booted from slot 1 or slot 2 and targets the opposite partition, ensuring the stock factory kernel is never overwritten.
- **ARM Performance Tuning**: Lowers PHP-FPM process concurrency and tunes frontend polling intervals to optimize responsiveness on low-power dual-core ARM CPUs.
- **Modern OpenSSH 9.2**: Full root & admin SSH support with out-of-the-box password and public-key authentication.

---

## Requirements

You can build on any modern Linux distribution using **Podman** or **Docker** (recommended for isolated, reproducible builds).

Required tools on the build host:
- `podman` or `docker` (loop-device access needs `--privileged` and usually `sudo`; rootless Podman fails with `losetup: cannot find an unused loop device`)
- `wget` (to fetch the kernel zip)
- Several GB of free disk (debootstrap + OpenMediaVault + the image is large)
- A USB flash drive (at least 4GB or 8GB recommended)

The build downloads Zyxel factory firmware from `ftp.zyxel.com` automatically and unpacks it under `fw/`. You do not prepare that tree by hand.

---

## Quick Start: Building the Image

A git clone is **not** enough to run `./build-debian.sh diskimage`. That mode only packs an already-built `armhf/` rootfs. A first build needs the Bookworm init-scripts archive, a NAS5xx kernel zip, a config for batch/OMV, then a full `batch` run.

### 1. Clone the repository

```bash
git clone https://github.com/petoknm/debian-nas-build.git
cd debian-nas-build
```

### 2. Create the Bookworm init-scripts archive

Git only ships `archives/debian-{stretch,buster,bullseye}-init-scripts.tar.gz`. The build extracts `archives/*debian-*bookworm*-init-scripts*.tar.gz` and, if that file is missing, **silently skips it**. The Bookworm tarball is a byte-for-byte copy of the Bullseye one:

```bash
cp archives/debian-bullseye-init-scripts.tar.gz archives/debian-bookworm-init-scripts.tar.gz
```

### 3. Download the NAS5xx kernel zip

The 6.12 kernel is not in git. Place the zip from [scpcom/linux](https://github.com/scpcom/linux/releases) in `kernel/` (filename must match `linux-image-*-armhf.zip`). The tree this README was written against used:

```bash
mkdir -p kernel
cd kernel
wget -N https://github.com/scpcom/linux/releases/download/v6.12.95-7018-sbc/linux-image-6.12.95-20260823-nas5xx-armhf.zip
cd ..
```

Newer `linux-image-*-nas5xx-armhf.zip` assets from later `scpcom/linux` releases can be substituted. Optional `kernel/gcc-*-armhf.zip` and `kernel/linux-tools-*-armhf.zip` packages are not required for the OMV image described here.

Without this zip the build still finishes, but it will not install Linux 6.12; first boot would only have the stock factory `uImage` extracted from firmware.

### 4. Write a batch config (skip the whiptail menus)

Without `etc/debian-build.conf`, a non-interactive run keeps `imageOmv=false` and `boardModel=nas540`. For OpenMediaVault 7 on a NAS542 with DHCP:

```bash
mkdir -p etc
cat > etc/debian-build.conf << 'EOF'
boardModel=nas542
FWGETURL="ftp://ftp.zyxel.com/NAS542/firmware/NAS542_V5.21(ABAG.0)C0.zip"
FWUSEVER="newer"
fanSpeed=keep
firstUser=share
imageMdMount=false
imageOmv=true
imageOmvInit=true
imageHostname=debian-nas
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
```

Change `boardModel` / `FWGETURL` for NAS520, NAS540, NAS326, or Kirkwood models. For an interactive build, omit this file and run without `batch`.

### 5. Full build in Podman / Docker

This installs host tools (including `unzip`, which a stock `debian:bookworm` image does not have), runs debootstrap, OpenMediaVault, firmware extract, kernel install, and writes `images/*.img.gz`. The first run takes a long time.

```bash
sudo podman run --rm -it --privileged \
  -v /dev:/dev \
  -v "$(pwd)":/build \
  -w /build \
  debian:bookworm \
  bash -c "apt-get update && apt-get install -y fdisk dosfstools e2fsprogs gdisk rsync binutils parted unzip && ./build-debian.sh batch"
```

`docker` works the same way if you are in the `docker` group. Do not drop `--privileged` or `/dev`; packing the image needs loop devices.

To rebuild only the USB image from an existing `armhf/` tree (after a successful full build):

```bash
sudo podman run --rm -it --privileged \
  -v /dev:/dev \
  -v "$(pwd)":/build \
  -w /build \
  debian:bookworm \
  bash -c "apt-get update && apt-get install -y fdisk dosfstools e2fsprogs gdisk rsync binutils parted unzip && ./build-debian.sh diskimage"
```

The output image is written under `images/`:
```
images/debian-nas-bookworm-YY.DDD-armhf.img.gz
```

---

## Flashing the USB Drive

Identify your USB stick (`lsblk`) and flash the image using `dd`:

```bash
# Decompress and flash (replace /dev/sdX with your actual USB drive)
zcat images/debian-nas-bookworm-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

---

## First Boot & Automated Kernel Flashing

1. **Insert the USB drive** into any USB port of your powered-off Zyxel NAS.
2. **Turn on the NAS.**
3. **What happens automatically:**
   - The NAS initially boots using the Zyxel stock USB pivot boot mechanism.
   - `debinit.sh` detects that it is running on the temporary factory kernel (3.2.x).
   - It runs `/usr/local/bin/zy-bb-env-and-kernel2-write`:
     - Detects the current NAND boot slot (`curr_bootfrom`).
     - Flashes **Linux 6.12 (`uImage`)** to the alternate NAND partition (`kernel2` or `kernel1`).
     - Updates the Barebox bootloader environment to set `next_bootfrom`.
     - Writes a flash log to `/boot/kernel2_flash.log` on the USB drive.
   - The NAS will **beep the buzzer twice** and automatically **reboot**.
4. **Second Boot (Native Linux 6.12):**
   - Barebox directly boots Linux 6.12 from NAND and mounts the USB drive as root (`/`).
   - The system boots into native Debian 12 with full systemd, networking, and OpenMediaVault 7 services.

---

## Accessing Your NAS

Once the NAS reboots and acquires an IP address via DHCP:

### Web Interface (OpenMediaVault)
- **URL**: `http://<nas-ip>` or `http://nas542.lan`
- **Username**: `admin`
- **Password**: `openmediavault`

### SSH Access
- **Command**: `ssh root@<nas-ip>`
- **Password**: `openmediavault`
- *Note*: You can also log in as `admin` (same password).

---

## Setting Up Storage & Existing RAID Arrays

### Importing an Existing mdadm RAID Array

If your NAS already has hard drives with an existing Linux software RAID (RAID 1, 5, or 6):

1. SSH into the NAS as root:
   ```bash
   ssh root@nas542.lan
   ```
2. Scan and assemble existing arrays:
   ```bash
   mdadm --assemble --scan
   ```
3. Save the array configuration to `/etc/mdadm/mdadm.conf`:
   ```bash
   /usr/share/mdadm/mkconf > /etc/mdadm/mdadm.conf
   update-initramfs -u
   ```
4. In the OpenMediaVault WebGUI, go to **Storage ➔ File Systems ➔ Mount Existing** to mount your data filesystems and set up shared folders.

---

## Performance Tips for Low-Power Dual-Core ARM

To get the smoothest performance out of the LS1024A / Cortex-A9 hardware:

1. **Dashboard Widgets**: In the OMV WebGUI, click the **Settings (gear/sliders)** icon at the top right of the **Dashboard**. Disable heavy, high-frequency widgets like *CPU graphs*, *RRD graphs*, and *Memory*. Keep only *System Information* and *File Systems*.
2. **PHP-FPM Pool**: Already tuned to `pm.max_children = 4` in `/etc/php/8.2/fpm/pool.d/openmediavault-webgui.conf` to avoid CPU context-switching starvation.
3. **Frontend Polling**: The frontend background task polling interval is pre-set to 2500ms (every 2.5s instead of 0.5s).

---

## Safety & Rollback

The stock factory kernel remains safe in NAND slot 1. If you ever need to restore the NAS to stock firmware:

1. Unplug the USB drive and reboot the NAS, **OR**
2. SSH into the NAS and set the boot slot back to stock:
   ```bash
   /firmware/sbin/info_setenv next_bootfrom 1
   reboot
   ```

---

## License

This project is licensed under the GPL-2.0 / MIT licenses compatible with Debian and upstream OpenMediaVault distributions.

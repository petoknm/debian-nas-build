#!/bin/sh
. /etc/debian-build.conf 2>/dev/null || true

[ -e /proc/mounts ] && ln -sf /proc/mounts /etc/mtab

# Mount essential kernel virtual filesystems
mkdir -p /sys /dev/pts /run/sshd /run/sendsigs.omit.d /run/lock /var/run/faillock /run/faillock
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devpts devpts /dev/pts -o gid=5,mode=620 2>/dev/null || true
chmod 0755 /run/sshd

# Ensure /boot has partition 1 (TC_BOOT) mounted if not already mounted
if [ ! -e /boot/uImage ]; then
  BOOT_DEV=$(blkid -L TC_BOOT 2>/dev/null || true)
  if [ -z "${BOOT_DEV}" ]; then
    BOOT_DEV=$(lsblk -rn -o NAME,LABEL 2>/dev/null | grep TC_BOOT | awk '{print "/dev/" $1}')
  fi
  if [ -z "${BOOT_DEV}" ]; then
    for d in /dev/sd?1 ; do
      if [ -b "$d" ]; then
        BOOT_DEV="$d"
        break
      fi
    done
  fi
  if [ -n "${BOOT_DEV}" ]; then
    mkdir -p /boot
    mount -t vfat "${BOOT_DEV}" /boot 2>/dev/null || mount "${BOOT_DEV}" /boot 2>/dev/null || true
  fi
fi

# AUTO-EXPAND ROOTFS: Expand USB partition 2 and ext4 filesystem to fill physical USB drive
if [ ! -f /boot/.rootfs_expanded ]; then
  chmod ugo+rx /usr/local/bin/zy-* 2>/dev/null || true
  if [ -x /usr/local/bin/zy-expand-rootfs ]; then
    echo "=========================================================="
    echo "=== Auto-expanding USB root filesystem to fill drive... ==="
    echo "=========================================================="
    /bin/bash /usr/local/bin/zy-expand-rootfs || true
  fi
fi

# AUTO-FLASH KERNEL 6.12: If booted under stock 3.2 kernel and not yet flashed
if uname -r 2>/dev/null | grep -q "^3\.2"; then
  if [ ! -f /boot/.kernel2_flashed ]; then
    echo "=========================================================="
    echo "=== Auto-flashing Linux 6.12 to alternate NAND slot... ==="
    echo "=========================================================="
    chmod ugo+rx /usr/local/bin/zy-* 2>/dev/null || true
    /bin/bash /usr/local/bin/zy-bb-env-and-kernel2-write > /boot/kernel2_flash.log 2>&1
    FLASH_RET=$?
    if [ ${FLASH_RET} -eq 0 ]; then
      touch /boot/.kernel2_flashed
      echo "=== Flash SUCCESSFUL! Rebooting into Linux 6.12 in 5 seconds... ===" >> /boot/kernel2_flash.log
      /sbin/buzzerc -t 2 2>/dev/null || true
      sync
      sleep 5
      reboot -f || true
      exit 0
    else
      echo "=== Flash FAILED with exit code ${FLASH_RET} ===" >> /boot/kernel2_flash.log
      /sbin/buzzerc -t 1 2>/dev/null || true
    fi
  fi
fi

/etc/init.d/networking start 2>/dev/null || true
/etc/init.d/hostname.sh start 2>/dev/null || true
/etc/init.d/resolvconf start 2>/dev/null || true
/etc/init.d/ssh restart 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true

rm -f /run/nologin
mount -a 2>/dev/null || true
/etc/init.d/rc 2 2>/dev/null || true

if [ "${imageOmv:-true}" = "true" ]; then
  /etc/init.d/openmediavault start 2>/dev/null || true
  /etc/init.d/php8.2-fpm restart 2>/dev/null || true
  /etc/init.d/nginx restart 2>/dev/null || true
  /etc/init.d/openmediavault-engined restart 2>/dev/null || /usr/sbin/omv-engined 2>/dev/null || true
fi

/etc/init.d/rpcbind restart 2>/dev/null || true
/etc/init.d/nfs-kernel-server restart 2>/dev/null || true
/etc/init.d/samba restart 2>/dev/null || true

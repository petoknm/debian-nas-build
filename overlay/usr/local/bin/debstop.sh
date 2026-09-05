#!/bin/sh
[ x$2 = x-w ] && exit 0
/sbin/setLED SYS GREEN BLINK

cd /tmp
mkdir /tmp/bin
mkdir /tmp/sbin
cp -p /oldroot/bin/busybox /tmp/bin/
cp -p /oldroot/bin/umount  /tmp/bin/
cp -p /oldroot/sbin/$1     /tmp/sbin/

/etc/init.d/rc 0

/etc/init.d/openmediavault-engined stop
/etc/init.d/cron stop
/etc/init.d/anacron stop
/etc/init.d/acpid stop
/etc/init.d/dbus stop
/etc/init.d/ntp stop
/etc/init.d/rsync stop
/etc/init.d/ssh stop

if [ -e /sbin/halt.distrib ]; then
  ln -sf /sbin/halt.distrib /sbin/halt
fi

if [ -e /sbin/reboot.distrib ]; then
  ln -sf /sbin/reboot.distrib /sbin/reboot
fi

if [ -e /bin/systemctl.distrib -a -e /bin/systemctl.druic ]; then
  ln -sf /bin/systemctl.distrib /bin/systemctl
fi

cd /tmp/bin/
./umount /usr
./umount /sbin
./umount /bin
./umount /lib
cd /tmp/sbin/
./$1

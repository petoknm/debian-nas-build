#!/bin/sh
mkdir /oldroot
mount -o bind /newroot/oldroot /oldroot
tar c /bin /etc /lib /sbin /usr /var | tar x -C /oldroot/
cp -p /init /oldroot/
cp -p /linuxrc /oldroot/

mkdir /boot
mkdir /media
mkdir /export
mkdir /opt
mkdir /run
mkdir /srv

cd /oldroot/bin/
#./mount /dev/sdb2 /newroot/
./mount -o bind /newroot/usr /usr
./mount -o bind /newroot/var /var
./mount -o bind /newroot/etc /etc
./mount -o bind /newroot/sbin /sbin
./mount -o bind /newroot/bin /bin
./mount -o bind /newroot/lib /lib

mkdir -p /newroot/export

mount -o bind /newroot/boot /boot
mount -o bind /newroot/export /export
mount -o bind /newroot/firmware /firmware
mount -o bind /newroot/home /home
mount -o bind /newroot/media /media
mount -o bind /newroot/root /root
mount -o bind /newroot/opt /opt
#mount -o bind /newroot/run /run
mount -o bind /newroot/srv /srv

mount -t tmpfs tmpfs /run
#mount -t tmpfs tmpfs /var/log
mount -t tmpfs tmpfs /tmp

mkdir -p /run/lock
chmod ugo+rw /run/lock
mkdir -p /run/dnsmasq
mkdir -p /run/resolvconf
mkdir -p /run/resolvconf/interface
mkdir -p /run/network
mkdir -p /run/screen

chown dnsmasq:nogroup /run/dnsmasq
chown root:netdev     /run/network
chown root:utmp       /run/screen

cp -ap /newroot/run/resolvconf/. /run/resolvconf/

if [ ! -e /sbin/halt.distrib ]; then
  dpkg-divert --local --rename /sbin/halt
fi

if [ -e /sbin/halt.distrib ]; then
  ln -sf /usr/local/bin/debhalt.sh /sbin/halt
fi

if [ ! -e /sbin/reboot.distrib ]; then
  dpkg-divert --local --rename /sbin/reboot
fi

if [ -e /sbin/reboot.distrib ]; then
  ln -sf /usr/local/bin/debreboot.sh /sbin/reboot
fi

if [ -e /bin/systemctl.distrib -a -e /bin/systemctl.druic ]; then
  ln -sf /bin/systemctl.druic /bin/systemctl
fi

cp -p /newroot/debinit.sh /
if [ -e /debinit.sh ]; then
  /debinit.sh
  killall telnetd
  /sbin/buzzerc -t 1
  /sbin/setLED SYS OFF
fi

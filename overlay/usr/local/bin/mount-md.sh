#!/bin/sh

mdadm --misc --scan --detail | grep ARRAY | while read i ; do
  d=`echo $i | cut -d " " -f 2`
  u=`echo $i | cut -d "=" -f 4 | cut -d ":" -f 1`
  mkdir -p /i-data/$u
  mount $d /i-data/$u
  [ -e /i-data/$u/sysdisk.img ] && umount /i-data/$u
done

for m in `ls /dev/mapper/vg_*-lv_*`; do
  d=${m}
  u=`echo ${d} | cut -d / -f 4 | cut -d - -f 2 | cut -d _ -f 2`
  mkdir -p /i-data/$u
  mount $d /i-data/$u
  [ -e /i-data/$u/sysdisk.img ] && umount /i-data/$u
done


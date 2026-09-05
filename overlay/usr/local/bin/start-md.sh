#!/bin/sh

/etc/init.d/mdadm start
/etc/init.d/mdadm-raid start
/etc/init.d/lvm2 start

for v in `vgs | cut -d ' ' -f 3`; do
  if [ ${v} != VG ]; then
    for l in `lvs ${v} | cut -d ' ' -f 3`; do
      if [ ${l} != LV ]; then
        dev=/dev/mapper/${v}-${l}
        dev="${dev#/dev/mapper/}"

        eval $(dmsetup splitname --nameprefixes --noheadings --rows "$dev")

        if [ "$DM_VG_NAME" ] && [ "$DM_LV_NAME" ]; then
          echo "$DM_VG_NAME/$DM_LV_NAME"
          lvm lvchange -aly --ignorelockingfailure "$DM_VG_NAME/$DM_LV_NAME"
          dmsetup mknodes "$dev"
        fi
      fi
    done
  fi
done


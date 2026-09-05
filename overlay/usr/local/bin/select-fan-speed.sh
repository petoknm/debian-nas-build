#!/bin/sh
fanSpeed=`sudo mmiotool -r 0x9045802C | cut -d ":" -f 2 | sed s/' '/''/g`

FSPEED=$(whiptail --default-item ${fanSpeed} --title "Image Creator Fan Speed" --cancel-button "Quit" --ok-button "Select" --menu "Which fan speed should be set on boot (NAS5xx only)?" 18 72 10 \
    "0x00000fa0" "600 rpm" \
    "0x00000dac" "750 rpm" \
    "0x00000bb8" "900 rpm" \
    "0x000009c4" "1000 rpm" \
    "0x000007d0" "1100 rpm" \
    "0x000005dc" "1200 rpm" \
    "0x000003e8" "1300 rpm" \
    "keep" "No change" \
    3>&1 1>&2 2>&3)

if [ ! -z $FSPEED ]; then
	fanSpeed=${FSPEED}
fi

if [ ${fanSpeed} != "keep" ]; then
  sudo mmiotool -w 0x9045802C ${fanSpeed}

  if grep 'mmiotool -w 0x9045802C' /etc/rc.local > /dev/null ; then
    sudo sed -i s/'mmiotool -w 0x9045802C .*'/'mmiotool -w 0x9045802C '${fanSpeed}/g /etc/rc.local
  fi
fi


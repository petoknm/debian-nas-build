#!/bin/sh
#
###############################
DEBUG="false"

if [ $# -ne 1 ]; then
cat 2>&1 << EOF
##############################################
fanctrl
-------
purpose: adjusts fan speed based on supplied argument

author: Tobias Rupf 
version: 1.5, date: 20170723
license: LGPL, no warranty, use at your own risk

arguments:
auto  = sets fan to low/high/full speed depending on
        current CPU temperature
off   = sets fan to off
low   = sets fan to low speed
high  = sets fan to high speed
full  = sets fan to full speed
daemon= start program in daemon mode
###############################################
EOF
exit 127
fi
 
DISK1=/dev/sda
DISK2=/dev/sdb
LOWLOW_TEMP=40  # this is Celsius, not Fahrenheit
LOW_TEMP=42
MAX_TEMP=45
MAXMAX_TEMP=49
###############################
# functions
# get current fan speed with
# cat /proc/linkstation/gpio/fan
 
fanoff() {
if [ "$(mmiotool -r 0x90458028)" != "Read from 0x90458028: 0x00000000" ] ; then
  if $DEBUG ; then echo "Switching fan off" ; fi
  mmiotool -w 0x90458028 0x0 >>/dev/null
#  mmiotool -w 0x9045802C 0x00000fa0 >>/dev/null
fi
}

fanlow() {
if [ "$(mmiotool -r 0x90458028)" != "Read from 0x90458028: 0x80001388" -o "$(mmiotool -r 0x9045802C)" != "Read from 0x9045802c: 0x00000fa0" ] ; then
  if $DEBUG ; then echo "Setting fan to low speed" ; fi
  mmiotool -w 0x90458028 0x80001388 >>/dev/null
  mmiotool -w 0x9045802C 0x00000fa0 >>/dev/null
fi
}

fanstandard() {
if [ "$(mmiotool -r 0x90458028)" != "Read from 0x90458028: 0x80001388" -o "$(mmiotool -r 0x9045802C)" != "Read from 0x9045802c: 0x00000dac" ] ; then
  if $DEBUG ; then echo "Setting fan to standard speed" ; fi
  mmiotool -w 0x90458028 0x80001388 >>/dev/null
  mmiotool -w 0x9045802C 0x00000dac >>/dev/null
fi
}
 
fanhigh() {
if [ "$(mmiotool -r 0x90458028)" != "Read from 0x90458028: 0x80001388" -o "$(mmiotool -r 0x9045802C)" != "Read from 0x9045802c: 0x000007d0" ] ; then
  if $DEBUG ; then echo "Setting fan high speed" ; fi
  mmiotool -w 0x90458028 0x80001388 >>/dev/null
  mmiotool -w 0x9045802C 0x000007d0 >>/dev/null
fi
}
 
fanfull() {
if [ "$(mmiotool -r 0x90458028)" != "Read from 0x90458028: 0x80001388" -o "$(mmiotool -r 0x9045802C)" != "Read from 0x9045802c: 0x000003e8" ] ; then
  if $DEBUG ; then echo "Setting fan to full speed" ; fi
  mmiotool -w 0x90458028 0x80001388 >>/dev/null
  mmiotool -w 0x9045802C 0x000003e8 >>/dev/null
fi
}
 
fanauto() {
  CPU_TEMP=$((`i2cget -y 0x0 0x0a 0x07`))
  if $DEBUG ; then echo "$(date +'%d.%m.%y %H:%M') CPU_TEMP=${CPU_TEMP}°C" ; fi
  if [ $CPU_TEMP -ge $MAXMAX_TEMP ] ; then fanfull
    elif [ $CPU_TEMP -ge $MAX_TEMP ] ; then fanhigh
    elif [ $CPU_TEMP -ge $LOW_TEMP ] ; then fanstandard
    elif [ $CPU_TEMP -ge $LOWLOW_TEMP ] ; then fanlow
    elif [ $CPU_TEMP -le $LOWLOW_TEMP ] ; then fanoff
  fi
}

################################
# main
 
case $1 in
 
auto)
  fanauto
;;

daemon)
  while true ; do
    fanauto
    sleep 60
  done # repeat it forever...
;;
 
low)
fanlow
;;
 
high)
fanhigh
;;
 
full)
fanfull
;;
 
off|stop)
fanoff
;;

-h|--help|-help|-\?)
exec fanctrl # calls fanctrl without arguments, thus displaying help...
;;
 
*)
echo "argument not valid."
echo
exec $0 # calls fanctrl without arguments, thus displaying help...
;;
esac

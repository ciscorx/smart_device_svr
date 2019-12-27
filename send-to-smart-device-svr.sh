#!/bin/bash
## This script is same as send_to_smart_device_svr.lua, except that its translated to bash; useful if you dont have luajit installed
function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

args=("$@") 
ELEMENTS=${#args[@]} 
start_at=0
ip_addr="localhost"
if valid_ip ${args[0]}; then
    start_at=1
    ip_addr=${args[0]}
fi
for (( i=$start_at;i<$ELEMENTS;i++)); do 
    tosend[${i}]=${args[${i}]} 
done
echo ${tosend[@]} | nc ${ip_addr} 29998

#!/bin/sh
cd /home/pi/scripts/smart_device_svr/
screen -dm /usr/local/bin/luajit ./smart_device_svr.lua

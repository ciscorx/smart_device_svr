# smart_device_svr
controls network devices using cron

## Commentary
     This server script schedules the switching on or off smart
       devices, such as, for example, the wifi of an at&t u-verse
       router connected to the local area network, depending on tcp
       messages received over port 29998 consisting of commands issued
       to do so via cron scheduling, or via telnet from an opened
       terminal, or from the send_to_smart_device_svr.lua client.
       Recognized commands include: `turn off wifi', `in 30 minutes
       turn wifi on for 2 hours and 30 minutes', `on 2009-11-05
       disable wifi for 30 minutes at 3:00 pm', `on mon,tue,wed turn
       on wifi for 5 hours at 3:00pm' and variations on these themes.
       When using telnet, the user is only allowed 30 seconds to type
       in a command.  In the case of a two part non-recurring on and
       off command, if there exists conflicting events in crontab
       which prevent the command from uninterrupted fulfillment, then
       those events are commented out in the crontab, effectively
       placed on hold until the given command can run its course,
       after which time they are effectively unheld.

       Additionally, at bootup, when the program is started, it
       assumes that the computer was offline during the last scheduled
       cron statement relating to turning on or off the device(s), and
       so, looks at the current users cron table and executes the last
       cron statement that happens to involve said device(s).


## Compiling notes:
          Compiling can be accomplished by the command make all, executed from the root directory of the unzipped archive.

          ccronexpr.so is compiled using the following statement:
             gcc -o ccronexpr.so ccronexpr.c -shared -fPIC -DCRON_USE_LOCAL_TIME
          
          luajit and luasocket must be compiled, in their respective directories, with:
             make && make install 

## Scheduling:
          This is the crontab I've been using ( set with crontab -e, notice that there are no seconds fields ):

            59 21 * * sun,mon,tue,wed,thu screen -dm emacs -nw -Q -l /home/pi/scripts/disable_wifi.el<br/>
            0 15 * * mon,tue,wed,thu,fri screen -dm emacs -nw -Q -l /home/pi/scripts/enable_wifi.el<br/>
            59 23 * * fri,sat screen -dm emacs -nw -Q -l /home/pi/scripts/disable_wifi.el<br/>
            0 7 * * sat,sun screen -dm emacs -nw -Q -l /home/pi/scripts/enable_wifi.el<br/>
   
## References:  
          ccronexpr.c is from https://github.com/staticlibs/ccronexpr

          The lua wrapper to ccronexpr.c is from
          https://github.com/tarantool/cron-parser/blob/master/cron-parser.lua

          table.save-1.0.lua is from http://lua-users.org/wiki/SaveTableToFile

          md5.lua is from https://github.com/kikito/md5.lua/blob/master/md5.lua

          LuaJIT-2.0.5 is from http://luajit.org/download.html



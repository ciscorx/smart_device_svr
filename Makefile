all:
	gcc -o ccronexpr.so ccronexpr.c -shared -fPIC -DCRON_USE_LOCAL_TIME
	gcc -o ccronexpr_misc_utils.so ccronexpr_misc_utils.c -shared -fPIC
	gcc -DCRON_USE_LOCAL_TIME -o cron_last_epoch_time_this_line_was_supposedly_executed cron_last_epoch_time_this_line_was_supposedly_executed.c ccronexpr.c
	gcc -DCRON_USE_LOCAL_TIME -o cron_next_epoch_time_this_line_should_execute cron_next_epoch_time_this_line_should_execute.c ccronexpr.c
install:
	cp send-to-smart-device-svr.sh /usr/bin
	cp start_smart_device_svr.sh /usr/bin

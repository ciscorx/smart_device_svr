all:
	gcc -o ccronexpr.so ccronexpr.c -shared -fPIC -DCRON_USE_LOCAL_TIME

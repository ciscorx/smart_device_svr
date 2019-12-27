#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int print_time( long long ticks) {
    printf("%lld\n", (long long) ticks);
}

int double_long_to_string( char* strbuffer_outarg, long long ticks ) {
    sprintf(strbuffer_outarg, "%lld\n", (long long) ticks); 
}

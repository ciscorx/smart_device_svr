/**********************************************************************
**  cron_next_epoch_time_this_line_should_execute.c                 **
**                                                                   **
** 
**  This program outputs to stdio the epoch time at which a given user
**  crontab expression will supposedly next execute, in addition to
**  the disposition element of the cron expression, if present.  The
**  expression should be comprised of one line from a user crontab
**  delimited by double quotes, passed as an argument.  Optionally, a
**  second argument may be supplied specifying either the epoch time,
**  or the iso8601 time, from which to start.  If this starting time
**  is in iso8601 then the output will also be in iso8601 format; if
**  the starting time is a malformed iso8601 datetime, such as
**  9999-99-99T99:99, then current time is assumed, but the prev time
**  outputted to stdio will be in iso8601 format.  All times are local not GMT
**
**  Examples:
**     ./cron_next_epoch_time_this_line_should_execute "0 22 * * mon,tue,wed,thu,fri disable_wifi.sh" 1569016800
**     This outputs: 1569034800 disable_wifi.sh
**
**     ./cron_next_epoch_time_this_line_should_execute "0 22 * * mon,tue,wed,thu,fri disable_wifi.sh" 2019-02-08T12:11
**     This outputs: 2019-02-08T22:00:00 disable_wifi.sh
**
**
**  Dependencies: 
**      ccronexpr.c borrowed from https://github.com/staticlibs/ccronexpr
**
**  To compile under linux:  
**      gcc -DCRON_USE_LOCAL_TIME -o cron_next_epoch_time_this_line_should_execute cron_next_epoch_time_this_line_should_execute.c ccronexpr.c
***********************************************************************/
#include "ccronexpr.h"
#include <stdlib.h>
#include <string.h>


int position_of_beginning_of_next_word_boundary(char* string, int initial_pos) {
    int pos;
    pos = initial_pos;
    if (string == NULL)
	return -1;
    while( string[pos] != NULL && string[pos] != ' ' )       
	pos = pos + 1;
    if (string[pos] == NULL)
	return -1;

    while( string[pos] == ' ' )	    
	pos = pos + 1;
       
    return pos;
}

int position_of_end_of_next_word_boundary(char* string, int initial_pos) {
    int pos;
    pos = initial_pos;
    if (string == NULL)
	return -1;
    while( string[pos] != NULL && string[pos] != ' ' )       
	pos = pos + 1;
    return pos;
}

/* The following function tries to parse a datetime string of the form
 *    YYYY-MM-DDTHH:MM or YYYYMMDDTHHMM or "YYYYMMDD HHMM", ignoring
 *    the seconds field if present, returning 0 if the string passed
 *    is a malformed datetime string, and 1 if it is a valid iso8601
 *    datetime string, else it returns -1 for neither.  
 *******************************************************************/

int try_to_parse_string_by_iso8601(char* string, struct tm* ts) {
    int strlength;
    char* time_delimiter_pos;
    int time_delimiter_index;
    char* tmp_element;
    int month, day, year, hour, minute;
    int index_offset;
    int i;
    time_t rawtime;
    struct tm current_time;

    strlength = strlen(string);

    index_offset = 0;
    if (string==NULL)
	return -1;
    time_delimiter_pos = strchr(string, ' ');
    if (time_delimiter_pos == NULL) {
	time_delimiter_pos = strchr(string, 'T');
	if (time_delimiter_pos == NULL)
	    return -1;
    }

    time_delimiter_index = (int) (time_delimiter_pos - string);
    if  (((time_delimiter_index == 8) || (time_delimiter_index == 10)) && (strlength - time_delimiter_index) >= 4 ) {
	if (time_delimiter_index == 10)
	    index_offset = 1;
	tmp_element = (char*) malloc(sizeof(char)*12);


	for (i=0;i<4;i++)
	    tmp_element[i] = string[i];
	tmp_element[4] = NULL;
	year = atoi(tmp_element);
	tmp_element[0] = string[4 + index_offset];
	tmp_element[1] = string[5 + index_offset];
	tmp_element[2] = NULL;
	month = atoi(tmp_element);
	tmp_element[0] = string[6  + index_offset*2];
	tmp_element[1] = string[7  + index_offset*2];
	tmp_element[2] = NULL;
	day = atoi(tmp_element);
	tmp_element[0] = string[9  + index_offset*2];
	tmp_element[1] = string[10  + index_offset*2];
	tmp_element[2] = NULL;
	hour = atoi(tmp_element);
	if (string[11 + index_offset*2] == ':') {
	    tmp_element[0] = string[12  + index_offset*2];
	    tmp_element[1] = string[13  + index_offset*2];
	} else {
	    tmp_element[0] = string[11  + index_offset*2];
	    tmp_element[1] = string[12  + index_offset*2];
	}
	tmp_element[2] = NULL;
	minute = atoi(tmp_element);
	free(tmp_element);	
	if (year >= 1900 && year <= 2038 && month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour >=0 && hour <=23) {
	     
	    time(&rawtime);
	    current_time = *localtime(&rawtime);  /* this is to find out if isdst */
	    ts->tm_gmtoff = current_time.tm_gmtoff;
	    ts->tm_zone = current_time.tm_zone;
	    ts->tm_isdst = current_time.tm_isdst;  /* daylight savings */
	    ts->tm_year = year - 1900;    /* year is years since 1900 */
	    ts->tm_mon = month - 1;       /* month starts at 0 */
	    ts->tm_mday = day;
	    ts->tm_hour = hour;
	    ts->tm_min = minute;
	    ts->tm_sec = 0;               /* seconds were ignored */

	} else
	    return 0;   /* 0 means malformed iso8601 date */	 
	return 1;    /* 1 means valid iso8601 date */
    }
}


int main(int argc, char *argv[]) {
    cron_expr expr;
    const char* err;
    char* cron_line;
    char* cron_line_disposition;
    char* cron_line_schedule;
    int i;
    int word_boundary_pos;
    int last_word_boundary_pos;
    int beginning_of_next_word_boundary;    
    time_t cur;
    time_t rawtime;
    int use_iso8601_datetime_format;
    char* strftime_result;
    struct tm ts;
    struct tm current_time;
    long offset_from_gmt;
    int daylight_savings;

    time(&rawtime);
    current_time = *localtime(&rawtime);
    offset_from_gmt = current_time.tm_gmtoff;
    daylight_savings = current_time.tm_isdst;

    use_iso8601_datetime_format = 0;
    last_word_boundary_pos = 0;
    beginning_of_next_word_boundary = 0;
    word_boundary_pos = 0;
    err = NULL;
    if (argc == 2 && *argv[1] != NULL && (argv[1][0] == '-' || argv[1][0] == 'h') ) {
	printf("\n");
	printf("     This program outputs to stdio the epoch time at which a given user\n");
	printf("     crontab expression was supposedly last executed, in addition to\n");
	printf("     the disposition element of the cron expression, if present.  The\n");
	printf("     expression should be comprised of one line from a user crontab\n");
	printf("     delimited by double quotes, passed as an argument.  Optionally, a\n");
	printf("     second argument may be supplied specifying the epoch time from\n");
	printf("     which to start.  BTW user crontab expressions dont have seconds fields.\n");
	printf("     Also, if the starting time is a malformed iso8601 datetime, such as\n");
	printf("     9999-99-99T99:99, then current time is assumed, but the prev time\n");
	printf("     outputted to stdio will be in iso8601 format.\n");
	printf("     All times are local, not GMT\n");

	printf("\n");
	printf("     Example:\n");
	printf("        ./cron_last_epoch_time_this_line_was_supposedly_executed \"0 22 * * mon,tue,wed,thu,fri disable_wifi.sh\" 1569016800\n");
	printf("        This outputs: 1569034800 disable_wifi.sh\n");
	printf("\n");
	printf("        ./cron_last_epoch_time_this_line_was_supposedly_executed \"0 22 * * mon,tue,wed,thu,fri disable_wifi.sh\" 2019-02-08T12:11\n");
        printf("        This outputs: 2019-02-08T22:00:00 disable_wifi.sh\n");
	exit(0);
    }


    if (argc == 2 || argc == 3) {
	cron_line_disposition = (char*) malloc(sizeof(char)*1000);
	cron_line_schedule = (char*) malloc(sizeof(char)*1000);
	strftime_result = malloc(sizeof(char)*100);
	strcpy(cron_line_schedule,"0 ");    /* user crontabs only have 5 schedule fields, so we must add one to represent seconds*/
	strcat(cron_line_schedule,argv[1]);
	for (i=0;i<6;i++) {
	    beginning_of_next_word_boundary = position_of_beginning_of_next_word_boundary(cron_line_schedule, word_boundary_pos);
	    
	    if (beginning_of_next_word_boundary != -1) {
		last_word_boundary_pos = word_boundary_pos;
		word_boundary_pos = beginning_of_next_word_boundary;
	
	    } else if (i<5) {
		free(cron_line_disposition);
		free(cron_line_schedule);
		free(strftime_result);
		exit(1);
	    }		     
	} 
	if (beginning_of_next_word_boundary != -1) {
	    last_word_boundary_pos = position_of_end_of_next_word_boundary(cron_line_schedule,last_word_boundary_pos);
	    strcpy(cron_line_disposition, cron_line_schedule + last_word_boundary_pos+1);
	    cron_line_schedule[last_word_boundary_pos] = NULL;	    
	}

	if (argc == 3) {
	    switch (try_to_parse_string_by_iso8601(argv[2],&ts)) {
	    case -1 :
		cur = (time_t) atof(argv[2]);	
		break;
	    case 0 :
		use_iso8601_datetime_format = 1;
		cur = time(NULL);   
		ts = *localtime(&cur);
		ts.tm_sec = 0;
		ts.tm_isdst = daylight_savings;
		cur = mktime(&ts);
		break;

	    case 1 :
	    /* truncate seconds to 0 if current time*/
		use_iso8601_datetime_format = 1;
		cur = mktime(&ts);
	    }
	} else {
	    /* truncate seconds to 0 if current time*/
	    cur = time(NULL);   
	    ts = *localtime(&cur);
	    ts.tm_sec = 0;
	    ts.tm_isdst = daylight_savings;
	    cur = mktime(&ts);
	}
    } else {
	printf("A single cron expression is required: one line from a user crontab delimited by double quotes.  Optionally, a second argument may be supplied specifying the epoch time from which to start.\nFor help see the -h option.\n");
	exit(1);
    }
    memset(&expr, 0, sizeof(expr));
    
    cron_parse_expr(cron_line_schedule, &expr, &err);

    time_t prev = cron_next(&expr, cur);  /* if you want the previous epoch time instead of next, simply change cron_next to cron_prev  */
    ts = *localtime(&prev);

    if (use_iso8601_datetime_format == 0) 
	if (beginning_of_next_word_boundary != -1)
	    printf("%lld %s\n", (long long) prev, cron_line_disposition);
	else
	    printf("%lld\n", (long long) prev);
    else {
	strftime(strftime_result,100,"%FT%H:%M:00",&ts);
	if (beginning_of_next_word_boundary != -1)
	    printf("%s %s\n", strftime_result, cron_line_disposition);
	else
	    printf("%s\n", strftime_result );
    }
 
    free(cron_line_disposition);
    free(cron_line_schedule);
    free(strftime_result);
}



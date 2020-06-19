#!/usr/local/bin/luajit
--[[

     This server script schedules the switching on or off of smart
       devices, such as, for example, the wifi of an at&t u-verse
       router connected to the local area network, depending on tcp
       messages received over port 29998 consisting of commands issued
       to do so via cron scheduling, or via telnet from an opened
       terminal, or from the send_to_smart_device_svr.lua client.
       Recognized commands include: `0`, `1', `turn off wifi', `in 30 minutes
       turn wifi on for 2 hours and 30 minutes', `on 2009-11-05
       disable wifi for 30 minutes at 3:00 pm', `on mon,tue,wed turn
       on wifi for 5 hours at 3:00pm' and variations on these themes.

     When using telnet, the user is only allowed 30 seconds to type
       in a command.  In the case of a two part non-recurring on and
       off command, if there exists conflicting events in crontab
       which prevent the command from uninterrupted fulfillment, then
       those events are commented out in the crontab, effectively
       placed on hold until the given command can run its course,
       after which time they are unheld.

     Additionally, at bootup, when the program is started, it
       assumes that the computer was offline during the last scheduled
       cron statement relating to turning on or off the device(s), and
       so, looks at the current users cron table and executes the last
       cron statement that happens to involve said device(s).


     Compiling notes:
          Compiling of ccronexpr.so may be accomplished by using the command `make all', executed from the root directory of the unzipped archive.

          ccronexpr.so is compiled using the following statement:
             gcc -o ccronexpr.so ccronexpr.c -shared -fPIC -DCRON_USE_LOCAL_TIME
          ccronexpr_misc_utils.so is compiled by the following:
             gcc -o ccronexpr_misc_utils.so ccronexpr_misc_utils.c -shared -fPIC          
   
          luajit and luasocket must be compiled, in their respective directories, with:
             make && make install 

          luasocket must have in its src directory a copy of lua.h luaconf.h and luaxlib.h pertaining to lua-5.1, which have already been provided.

          The following scripts are copied to /usr/bin:
             send_to_smart_device_svr.lua  
             start_smart_device_svr.sh


     Scheduling:
          This is an example crontab I've been using ( set with crontab -e, notice that there are no seconds fields ):


            59 22 * * sun,mon,tue,wed,thu screen -dm emacs -nw -Q -l /home/pi/scripts/disable_wifi.el

            0 15 * * mon,tue,wed,thu,fri screen -dm emacs -nw -Q -l /home/pi/scripts/enable_wifi.el
            59 23 * * fri,sat screen -dm emacs -nw -Q -l /home/pi/scripts/disable_wifi.el
            0 7 * * sat,sun screen -dm emacs -nw -Q -l /home/pi/scripts/enable_wifi.el

   
     References:  
          ccronexpr.c is from https://github.com/staticlibs/ccronexpr

          The lua wrapper to ccronexpr.c is from
          https://github.com/tarantool/cron-parser/blob/master/cron-parser.lua with some debugging

          table.save-1.0.lua is from http://lua-users.org/wiki/SaveTableToFile

          md5.lua is from https://github.com/kikito/md5.lua/blob/master/md5.lua

          LuaJIT-2.0.5 is from http://luajit.org/download.html

     Authors/Maintainers: ciscorx@gmail.com
       Version: 0.8
       Commit date: 2020-06-19

       7z-revisions.el_rev=1074.0
       7z-revisions.el_sha1-of-last-revision=3193ed6ab3d188de7666315fa437f6af3ee11f5a
--]]

local version = "0.8"
local devices_list = {"wifi", "svr"}
local scripts_dir = io.popen"pwd":read'*l'
local dispositions_cmdline = {{"screen -dm emacs -nw -Q -l "..scripts_dir.."/disable_wifi.el","screen -dm emacs -nw -Q -l "..scripts_dir.."/enable_wifi.el","screen -dm emacs -nw -Q -l "..scripts_dir.."/reboot_wifi.el"},{"sudo shutdown -h now",nil,"sudo reboot"}}
local disposition_states = {{"off","on","reboot"},{"off","on","reboot"}}
local device_ip_addresses = { wifi="192.168.1.254", svr="localhost"}
local device_status_query_texts = { wifi={ '','>','<', "2.4 GHz Radio Status","Network name","Status","span class"}}
local devices_for_which_to_execute_last_cron_statement_on_boot = {}

dofile('inspect.lua');local ins=require('inspect')
dofile('pp.lua');local pp=require('pp')
dofile('md5.lua');local md5 = require('md5')
local socket = require('socket')
local os = require('os')
local ffi = require('ffi')

ffi.cdef[[
typedef long long __time_t;
typedef __time_t time_t;
typedef struct {
    uint8_t seconds[8];
    uint8_t minutes[8];
    uint8_t hours[3];
    uint8_t days_of_week[1];
    uint8_t days_of_month[4];
    uint8_t months[2];
} cron_expr;
void cron_parse_expr(const char* expression, cron_expr* target, const char** error);
time_t cron_next(cron_expr* expr, time_t date);
time_t cron_prev(cron_expr* expr, time_t date);
int printf(const char *fmt, ...);
int print_time( long long ticks);
int double_long_to_string( char* strbuffer_outarg, long long ticks);
]]

local ccronexpr = ffi.load("./ccronexpr.so")
local ccronexpr_misc_utils = ffi.load("./ccronexpr_misc_utils.so")
local errormsg_file = "/tmp/.errormsg.txt"
local smart_device_client_program = "send_to_smart_device_svr.lua"
-- local smart_device_client_program = "send-to-smart-device-svr.sh"
local port_number_for_which_to_listen = 29998
local onhold_token = "^#%s*ON%s*HOLD%s*(%x*)%s*(%x*)%s*#%s*"
local tmp_token = " #TMP"  -- this token must include a preceding space
local default_actions_list = {"turn","disable","enable","reboot"}
local default_action_disposition_numbers = {0,1,2,3}

local months = {jan=1,feb=2,mar=3,apr=4,may=5,jun=6,jul=7,aug=8,sep=9,oct=10,nov=11,dec=12}
local dow = {su=0,mo=1,tu=2,we=3,th=4,fr=5,sa=6}
local dow_recurring = {sundays=0,mondays=1,tuesdays=2,wednesdays=3,thursdays=4,fridays=5,saturdays=6}
local dow_recurring_abbrv = {sun=0,mon=1,tue=2,wed=3,thu=4,fri=5,sat=6}
local time_zoneinfo = { z=0,ut=0,gmt=0,pst=-8*3600,pdt=-7*3600
			,mst=-7*3600,mdt=-6*3600
			,cst=-6*3600,cdt=-5*3600
			,est=-5*3600,edt=-4*3600}


-- This split string function works well and was lifted from https://stackoverflow.com/a/7615129
local function split(inputstr, sep) 
   sep=sep or '%s' 
   local t={} 
   for field,s in string.gmatch(inputstr, "([^"..sep.."]*)("..sep.."?)") do
      table.insert(t,field)
      if s=="" then
	 return t
      end
   end
end


local function sleep(sec)
    socket.select(nil, nil, sec)
end

-- Count the number of times a value occurs in a table 
local function tblCountFreq(tt, item)
  local count
  count = 0
  for ii,xx in pairs(tt) do
    if item == xx then count = count + 1 end
  end
  return count
end

-- Remove duplicates from a table array (doesn't currently work
-- on key-value tables)
local function tblRemove_duplicates_that_are_not_blank_or_comments(tt)
  local newtable
  newtable = {}
  for ii,xx in ipairs(tt) do
     if not xx:match'^(%s*)#'and xx:match'^%s*(%S+)' and tblCountFreq(newtable, xx) == 0 then
	newtable[#newtable+1] = xx
     elseif xx:match'^(%s*)#' or xx:match'^(%s*)$' then
	newtable[#newtable+1] = xx	 
     end
  end
  return newtable
end


local function make_reverse_lookup_table(tbl)
   local reverse_lookup_table = {}
   for k,v in pairs(tbl) do
      reverse_lookup_table[v] = k
   end
   return reverse_lookup_table
end

local function reversed_ipairs_iter(t,i)
   i = i - 1
   if i ~= 0 then
      return i, t[i]
   end
end

local function reversed_ipairs(t)
   return reversed_ipairs_iter, t, #t + 1 
end

local function make_associative_table_between_two_arrays(array1, array2)
   associative_table = {}
   for k,v in ipairs(array1) do
      associative_table[v] = array2[k]
   end
   return associative_table
end

local actions_to_disposition_number = make_associative_table_between_two_arrays(default_actions_list, default_action_disposition_numbers)
local device_in_question_to_device_number = make_reverse_lookup_table(devices_list)
local dow_recurring_abbrv_reverse_lookup = make_reverse_lookup_table(dow_recurring_abbrv)
local dispositions_to_device = {}
local dispositions_to_action = {}
for i,j in ipairs(devices_list) do
   for k,v in ipairs(dispositions_cmdline) do
      dispositions_to_device[v] = i
      dispositions_to_action[v] = k
   end
end


local function Set (list)
   local set = {}
   for _, l in ipairs(list) do
      set[l] = true
   end
   return set
end

local function add_space_to_beginning_and_ending_of_each_list_item(array)
   for i,v in ipairs(array) do  
      if type(array[i]) == "string" then
	 array[i] = " " .. (v:match'^%s*(.*%S)' or "") .. " "
      end
   end
end

local function add_space_to_beginning_and_ending_of_each_list_item_for_each_array(...)
   for i = 1, select("#",...) do
      array = select(i,...)
      if type(array) == "table" then
	 add_space_to_beginning_and_ending_of_each_list_item(array)
      end
   end
end

-------------------------- grammar settings ----------------

local is_action = Set(default_actions_list)
local is_device = Set(devices_list)
local prepositions_list = {"in","for", "until", "from", "to", "til"}
local date_specifiers_list = {"until", "til"}				
local prepositions_pos_index = {}

-- local is_disposition_state = {} 
-- for k,_ in ipairs(devices_list) do
--    table.insert(is_disposition_state, Set(dispositions_list[k]))
-- end

local is_preposition = Set(prepositions_list)
local is_date_specifier = Set(date_specifiers_list)

local keywords_array = {'on','in','for','at','from','until', 'til', 'through',  'throughout', 'to', 'this', 'this week', 'next', 'next week', 'starting', 'beginning'}
local duration_keywords = { 'for' }
local date_in_question_keywords = { 'on', 'at', 'from', 'starting', 'beginning' }
local date_range_ends_keywords = {'to', 'until', 'til', 'through'}

local date_in_question_by_duration_keywords = { 'in'}
local date_range_delimiting_keywords = { 'from', 'to', 'until', 'til', '-' }
add_space_to_beginning_and_ending_of_each_list_item_for_each_array(
   keywords_array, 
   date_in_question_keywords, 
   date_in_question_by_duration_keywords, 
   duration_keywords, date_range_ends_keywords, 
   date_range_delimiting_keywords)
pp(keywords_array)
local is_range_ends_keyword = Set(date_range_ends_keywords)

local randomcharset = {}  do -- [0-9a-zA-Z]
    for c = 48, 57  do table.insert(randomcharset, string.char(c)) end
    for c = 65, 90  do table.insert(randomcharset, string.char(c)) end
    for c = 97, 122 do table.insert(randomcharset, string.char(c)) end
end

local function randomString(length)
    if not length or length <= 0 then return '' end
    math.randomseed(socket.gettime()*10000)
    return randomString(length - 1) .. randomcharset[math.random(1, #randomcharset)]
end



--- Check if a file or directory exists in this path
local function exists(file)
   local ok, err, code = os.rename(file, file)
   if not ok then
      if code == 13 then
         -- Permission denied, but it exists
         return true
      end
   end
   return ok, err
end

--- Check if a directory exists in this path
local function isdir(path)
   -- "/" works on both Unix and Windows
   return exists(path.."/")
end

local function file_exists(name)
   local f=io.open(name,"r")
   if f~=nil then io.close(f) return true else return false end
end

local function tblMerge(t1, t2)
   pp("tblMerge()")
   pp(t1)
   pp(t2)
   if not t1 then
      t1 = {}
   end
   if not t2 or type(t2) ~= "table" then
      return t1
   end
   
    for k,v in pairs(t2) do
        if type(v) == "table" then
            if type(t1[k] or false) == "table" then
                tblMerge(t1[k] or {}, t2[k] or {})
            else
                t1[k] = v
            end
        else
            t1[k] = v
        end
    end
    return t1
end


local function tblShallowMerge(t1, t2)
   pp("preparing tblshallowMerge()")
   pp(t1)
   pp(t2)
   if not t1 then
      t1 = {}
   end
   if not t2 or type(t2) ~= "table" then
      return t1
   end
   pp("shallowmerge begins---")
    for k,v in pairs(t2) do
       t1[k] = v       
    end
    pp(t1)
    return t1
end


local next = next
local function is_empty(t)
   if t and next(t) then
      return false
   else
      return true
   end
end

local function tblShallow_copy(t)
  local t2 = {}
  if is_empty(t) then
     return t2
  end
  for k,v in pairs(t) do
    t2[k] = v
  end
  return t2
end

local function tblShallow_fill_in_missing(t1, t2)
   if is_empty(t2) then
      return t1
   end
   pp("tblShallow_fill_in_missing()")
   pp(ins(t1))
   pp(ins(t2))
   for k,v in pairs(t2) do
	 if not t1[k] then
	    t1[k] = v
	 end
   end
   return t1
end

local function tblShallow_is_equal(t1, t2)
   if is_empty(t2) then
      if is_empty(t1) then 	 
	 return true
      else
	 return false
      end
   end
   pp("tblShallow_is_equal()")
   pp(ins(t1))
   pp(ins(t2))
   for k,v in pairs(t2) do
	 if t1[k] ~= v then
	    return false
	 end
   end
   for k,v in pairs(t1) do
	 if t2[k] ~= v then
	    return false
	 end
   end
   return true
end

local function tblCopy_doesnt_work(obj, seen)
   if type(obj) ~= 'table' then return obj end
   if seen and seen[obj] then return seen[obj] end
   local s = seen or {}
   local res = setmetatable({}, getmetatable(obj))
   s[obj] = res
   for k, v in pairs(obj) do res[tblCopy(k, s)] = tblCopy(v, s) end
   return res
end



local function is_month (str)
   return months[str:sub(1,3)]
end

local function is_dow (str)
   return dow[str:sub(1,2)] 
end

local function is_dow_recurring_abbrv (str)
   return dow_recurring_abbrv[str:sub(1,3)] 
end

local function find_dow(str)
   local possible_pos, possible_endpos, possible_dow
   local dow_found = false
   local startingpos = 1
   if not str then
      return nil
   end
   repeat
      possible_pos, possible_endpos, possible_dow = string.find(str," ([mtwtfss][ouehrau])", startingpos)
      if possible_dow then
	 if not dow[possible_dow] then
	    startingpos = possible_endpos
	 else
	    dow_found = true
	 end
      else
	 return nil
      end
   until dow_found
   return dow[possible_dow] 
end


local function isInteger(n)
  return n==math.floor(n)
end

local function isLeapYear(year)
   if isInteger(year/400) then
      return true 
   elseif isInteger(year/100) then
      return false
   elseif isInteger(year/4) then
      return true
   else 
      return false
   end
end

-- from https://artofmemory.com/blog/how-to-calculate-the-day-of-the-week-4203.html ; sunday=0
-- this algorthm is slow but interesting
local function dow_from_date(date)
   local leap_year, leap_year_code
   local year,month,day = date.year,date.month,date.day
   local year_string = tostring(year)
   local cen = year_string:sub(1,2)
   local YY = tonumber(year_string:sub(3,4))
   local year_code = (YY + math.floor(YY/4))%7 
   local month_code_chart = {0,3,3, 6,1,4, 6,2,5, 0,3,5}
   local century_code_chart = {["17"]=4,["18"]=2,["19"]=0,["20"]=6,["21"]=4,["22"]=2,["23"]=0}
   local leap_year = 0
   if isInteger(year/400) then
      leap_year = true 
   elseif isInteger(year/100) then
      leap_year = false
   elseif isInteger(year/4) then
      leap_year = true
   else 
      leap_year = false
   end

   if leap_year and month < 3 then
      leap_year_code = 1
   else
      leap_year_code = 0
   end
   return (year_code + month_code_chart[month] + century_code_chart[cen] + day - leap_year_code) %7
end 

-- This algorithm only works for years between 2000 and 2100; sunday = 0
local function calculate_dow_from_date(date)
   local y,m,d = date.year, date.month, date.day
   local result
   local C = 20
   local Y
   if m < 3 then
      y = y - 1
   end
   Y = y - 2000
   local M = m - 2
   if M == 0 then 
      M = 12
   elseif M == -1 then
      M = 11
   end
   result = ( d + math.floor(2.6*M - 0.2) - 2*C + Y + math.floor(Y/4) + math.floor(C/4))%7  
   return result
end

local function print_current_datetime()
   local now = os.date("*t")
   pp(string.format("%04d",now.year).."/"..string.format("%02d",now.month).."/"..string.format("%02d",now.day).." "..string.format("%02d",now.hour)..":"..string.format("%02d",now.min)..":"..string.format("%02d",now.sec))
end

local function days_in_month_of(month, year)
   local leap_year
   if isLeapYear(year) then
      leap_year = 1
   else
      leap_year = 0
   end
   local days_per_month = {31,28+leap_year,31,30,31,30,31,31,30,31,30,31}
   return days_per_month[month]
end

local function date_of_the_nth_wday_of_m(nth,wday,month)
   pp("date_of_the_nth_wday_of_m()")
   local now = os.date("*t")
   local year = os.date("%Y")
   local occurrence = 0
   local nth_num
   if not (nth and wday and month) then
      return nil
   end
   if type(month) == "string" then
      month = months[month]
   end
   if wday == 0 then
      wday = 7
   end

   if now['month'] > month then
      year = year + 1
   end
   local number_of_days_in_month = days_in_month_of(month,year)
   if type(nth) == "string" then 
      if nth == "last" or nth == "5th" or nth == "fifth" then
	 nth_num = 5
      elseif nth == "second to last" or nth == "2nd to last" then
	 nth_num = 4	 
      elseif nth == "first" or nth == "1st" then
	 nth_num = 1
      elseif nth == "second" or nth == "2nd" then
	 nth_num = 2	 
      elseif nth == "fourth" or nth == "4th" then
	 nth_num = 4	
      end
   else
      nth_num = nth
      nth = ""
   end

   if nth_num > 5 or nth_num < 1 or wday <0 or wday >7 then
      return nil
   end

   local day_cntr = 1
   local date_cntr
   local dow_of_date
   local day_of_last_occurrence
   local day_of_nth_occurrence = 0
   for i=1,number_of_days_in_month do 
      date_cntr = {year = year, month = month, day = i}      
      dow_of_date =  calculate_dow_from_date( date_cntr )
      if dow_of_date == wday then
	 occurrence = occurrence + 1
	 day_of_last_occurrence = i
	 if occurrence == nth_num then
	    day_of_nth_occurrence = i
	 end
      end
   end
   if nth == "last" then
      day_of_nth_occurrence = day_of_last_occurrence
   elseif nth == "second to last" or nth == "2nd to last" then
      day_of_nth_occurrence = day_of_last_occurrence - 7
   end 
   return {year = year, month = month, day = day_of_nth_occurrence}
end

-- calculated from todays date, projects the future date of the given
-- day of the week, which must be a number from 0 to 7, 0 and 7 both
-- equating to sunday.  A dow of 0 with occurrence of 2 means the
-- sunday after next.  occurrence is assumed 1 if nil.
local function date_of_next_dow(dow, occurrence)
   pp("running date_of_next_dow")
   if type(dow) ~= "number" or dow > 7 or dow < 0 then
      pp("date_of_next_dow returns nil")
      pp(dow)
      pp(type(dow))
      return nil
   end
   if dow == 0 then
      dow = 7
   end
   if not occurrence then
      occurrence = 1
   end
   local timecnt = os.time()
   local datetbl ={}
   pp("occurrence of date_of_next_dow")
   pp(occurrence)
   while occurrence > 0 do
      repeat
	 timecnt = timecnt + 60*60*24
	 datetbl = os.date("*t", timecnt)
      until datetbl.wday==dow
      occurrence = occurrence - 1
   end
   return datetbl
end


-- takes out the phrase `for the next' and replaces it with `for'
local function replace_for_the_next_clause(str)
   local startpos,endpos = str:find(" for%s+the%s+next ")
   if startpos then
      return str:sub(1,startpos + 4)..str:sub(endpos+1,-1)
   else
      return str
   end
end



-- returns a list of all elements from table A that are not in table B
local function tblSet_difference (A, B)
   local newhash = {}
   for k,v in pairs(A) do
      newhash[v]=true
   end
   for k,v in pairs(B) do
      newhash[v]=nil
   end
   local tblReturn = {}
   local i = 0
   for k,v in pairs(A) do
      if newhash[v] then
	 i=i+1
	 tblReturn[i]=v
      end
   end
   return tblReturn
end


-- This function takes a list of lines and returns its contents in a
-- new list, sorted and after having removed all extra occurrences of
-- each line within the list.
local function tblUniquify (tblInput)
   local tblInputCopy = tblShallow_copy(tblInput)
   local tblNew = {}
   local last_line
   table.sort(tblInputCopy)
   for k,v in ipairs(tblInputCopy) do
      if v ~= last_line then
	 table.insert(tblNew,v)
      end
      last_line = v
   end
   return tblNew
end

-- This function returns 3 values: the str after the dow part is
-- extracted, the dow string used as the 5th field in the crontable
-- schedule, and a string to be pasted to after the final cron
-- schedule and before its disposition string, used for things like
-- `every other week'.  A single 3 letter reference to a day of the
-- week is not enough to qualify as recurring unless its proceeded by
-- the word 'every'.  Whereas, a comma delineated list of 3 letter
-- abbreviations of days of the week is assumed to be recurring.  A
-- single 3 letter dow reference could simply be referring to a
-- particular day of the week, this week, and not to a recurring
-- event.
local function extract_dow_recurring(str)
   
   local possible_pos, possible_endpos,possible_dow
   local possible_dow2
   local firstpos, lastpos
   local prepend_to_cron_disposition 
   local tblSpanning = {}
   local tblSpanning_except = {}
   local except_pos, except_pos_end
   local Spanning_count
   local tblDow_nums = {}
   local tblDow_num_exceptions = {}
   local tblDelete_pos_range = {}
   local i = 0
   str = " " .. str .. " "
   if str:match(' this ') or str:match(' next ') then
      return
   end
   local function parse_spanning ()
      local dow_num = dow_recurring_abbrv[possible_dow] 
      local j
      local dow_num2 = dow_recurring_abbrv[possible_dow2] 
      if dow_num and dow_num2 and dow_num ~= dow_num2 then
	 if dow_num > dow_num2 then
	    j = dow_num2 + 7
	 else
	    j = dow_num2
	 end
	 if except_pos and except_pos < possible_pos then
	       --  table.insert(tblDow_num_exceptions,dow_recurring[possible_dow])
	    table.insert(tblSpanning_except, {dow_num,j})
	 else
	    table.insert(tblSpanning, {dow_num,j})
	    --   table.insert(tblDow_nums, dow_recurring[possible_dow])
	 end
	    
	 table.insert( tblDelete_pos_range , {possible_pos,possible_endpos})
      end
      startingpos=possible_endpos
   end

   local function find_except_pos()
      except_pos, except_pos_end = string.find(str," except ")
      if not except_pos then
	 except_pos, except_pos_end = string.find(str," but not ")
      end      
   end

   local function delete_pos_range()
      if #tblDelete_pos_range ~= 0 then
	 pp('delete_pos_range:')
	 pp(ins(tblDelete_pos_range))
	 pp(str)
	 for _,v in reversed_ipairs(tblDelete_pos_range) do
	    str=str:sub(1,v[1]-1)..str:sub(v[2]+1,-1)
	 end
	 pp(str)
	 tblDelete_pos_range = {}
	 find_except_pos()
      end
   end
   
   local tmp_pos, tmp_end_pos = string.find(str," every day ")
   if not tmp_pos then
      tmp_pos, tmp_end_pos = string.find(str, " each day ")
      if not tmp_pos then
	 tmp_pos, tmp_end_pos = string.find(str, " all week long ")
	 if not tmp_pos then
	    tmp_pos, tmp_end_pos = string.find(str, " all week ")
	 end
      end
   end
   if tmp_pos then
      str=str:sub(1,tmp_pos)..str:sub(tmp_end_pos,-1)
      tblDow_nums = { 0,1,2,3,4,5,6 }
   end
   
   local tmp_pos, tmp_end_pos, tmp_val = string.find(str," every other week ")
   if tmp_pos then
      prepend_to_cron_disposition = [[ expr `date +%\%d` %\% 2 > /dev/null || ]]
   else
      tmp_pos, tmp_end_pos = string.find(str, " every third week ")
      if tmp_pos then
	 prepend_to_cron_disposition = [[ expr `date +\%d` \% 3 > /dev/null || ]]
      else
	 tmp_pos, tmp_end_pos = string.find(str, " every 3rd week ")
	 if tmp_pos then
	    prepend_to_cron_disposition = [[ expr `date +\%d` \% 3 > /dev/null || ]]
	 else
	    tmp_pos, tmp_end_pos, tmp_val = string.find(str, " every (%d+)th week ")
	    if tmp_pos then
	       prepend_to_cron_disposition = [[ expr `date +\%d` \% "..tmp_val.." > /dev/null || ]]
	    end
	 end
      end
   end
   if tmp_pos then
      str=str:sub(1,tmp_pos)..str:sub(tmp_end_pos,-1)
   end
	 
	 
   find_except_pos()
   
   -- look for dash delineated spanning of abbreviated or unabbreviated dow
   local startingpos = 1
   repeat
      possible_pos, possible_endpos,possible_dow,  possible_dow2 = string.find(str,"([mtwtfss][ouehrau][neduitn])%l*%s*-%s*([mtwtfss][ouehrau][neduitn])%l*", startingpos)
      if possible_dow then
	 parse_spanning()	 
	 startingpos=possible_endpos
      else
	 break
      end
   until false 
   delete_pos_range() 
   
   

   -- -- look for spanning via `through'
   -- startingpos = 1
   -- repeat
   --    possible_pos, possible_endpos,possible_dow,  possible_dow2 = string.find(str,"([mtwtfss][ouehrau][neduitn])%s*through%s*([mtwtfss][ouehrau][neduitn])", startingpos)
   --    if possible_dow then
   -- 	 parse_spanning()
   -- 	 startingpos=possible_endpos
   --    else
   -- 	 break
   --    end
   -- until false
   -- delete_pos_range()

   -- look for `through' delineated spanning of un-abbreviated dow
   startingpos = 1
   repeat
  --    possible_pos, possible_endpos,possible_dow,  possible_dow2 = string.find(str,"([mtwtfss][ouehrau][neduitn][dsnrdud][adesara][yasdydy]%l*)%s*through%s*([mtwtfss][ouehrau][neduitn][dsnrdud][adesara][yasdydy]%l*)", startingpos)
      possible_pos, possible_endpos,possible_dow,  possible_dow2 = string.find(str,"([mtwtfss][ouehrau][neduitn])%l*%s*through%s*([mtwtfss][ouehrau][neduitn])%l*", startingpos)
      if possible_dow then
	 parse_spanning()
	 startingpos=possible_endpos
      else
	 break
      end
   until false
   delete_pos_range()
   
   -- translate the spanned numbers to individual dow numbers
   if #tblSpanning > 0 then
      for k,v in ipairs(tblSpanning) do
	 for i = v[1],v[2] do
	    table.insert(tblDow_nums, i % 7)
	 end
      end
   end
   if #tblSpanning_except > 0 then
      for k,v in ipairs(tblSpanning_except) do
	 for i = v[1],v[2] do
	    table.insert(tblDow_num_exceptions,i % 7)
	 end
      end
   end

   
   -- look for recurring dow in the form of mondays tuesdays, etc.
   startingpos = 1
   i = 0
   repeat
      pp'startingpos'
      pp(startingpos)
      possible_pos,possible_endpos,possible_dow = string.find(str," ([mtwtfss][ouehrau])", startingpos)
      pp'possible_dow'
      pp(possible_dow)	 
      if possible_dow then
	 possible_pos,possible_endpos,possible_dow = string.find(str, "(%l+)", possible_pos)
	 
	 pp'possible_pos'
	 pp(possible_pos)
	 pp'possible_endpos'
	 pp(possible_endpos)
	 pp'possible_dow'
	 pp(possible_dow)
	 -- startingpos = possible_endpos
	 if dow_recurring[possible_dow] then
	    i = i + 1
	    
	    if i == 1 then
	       firstpos = possible_pos
	    end
	    lastpos = possible_endpos	    
	    if except_pos and except_pos < startingpos then
	       table.insert(tblDow_num_exceptions,dow_recurring[possible_dow])
	    else
	       table.insert(tblDow_nums, dow_recurring[possible_dow])
	    end
	    table.insert( tblDelete_pos_range , {possible_pos,possible_endpos})
	    
	 end
	 
	 startingpos = possible_endpos
      else
	 break
      end
   until false
   delete_pos_range()
   
   -- look for 3 letter abbreviated days of the week separated by commas, there must exist at least 2 abbreviated dows for this to work, unless proceeded by the word `every'.
   pp('repeating search for dow, this time looking for commas')
   startingpos = 1
   i = 0

   local first_iteration = true
   local possible_endpos
   local comma
   repeat
      
      possible_pos,possible_endpos, possible_dow, comma = string.find(str,"([mtwtfss][ouehrau][neduitn])([, ]+)", startingpos)
      
      
      if possible_dow then
	 pp(possible_dow)
	 startingpos = possible_endpos
	 local found_dow =  dow_recurring_abbrv[possible_dow]
	 
	 if found_dow then
	    comma = comma:gsub(' ','')
	    local every_pos = str:find("every%s+"..possible_dow)
	    if every_pos then 
	       possible_pos = every_pos
	    end
	    local except_pos2 = str:find("except%s+"..possible_dow)
	    if (i==0 and (every_pos or comma == ',' or except_pos2)) or i ~= 0 then
				       
	       pp('found')
	       if except_pos and except_pos < startingpos then
		  table.insert(tblDow_num_exceptions,dow_recurring_abbrv[possible_dow])
	       else
		  table.insert(tblDow_nums, dow_recurring_abbrv[possible_dow])
	       end
	       table.insert( tblDelete_pos_range , {possible_pos,possible_endpos})
	       i = i + 1
	       lastpos = possible_endpos
	    end
	 end
      else
	 break
      end
   until false
   delete_pos_range() 
   tblDow_nums = tblUniquify (tblDow_nums)
   tblDow_num_exceptions = tblUniquify (tblDow_num_exceptions)  

   local tblFinal_dow_nums = tblSet_difference (tblDow_nums, tblDow_num_exceptions)
   
   if except_pos then
      str = str:sub(1,except_pos)..str:sub(except_pos_end,-1)
   end
   
   local retval = ""
   if #tblFinal_dow_nums ~= 0 then
      for _,k in ipairs(tblFinal_dow_nums) do
	 retval = retval .. "," .. dow_recurring_abbrv_reverse_lookup[k]
      end
      retval = retval:gsub("^,","")
      return str,retval, prepend_to_cron_disposition
      
   else
      return nil, nil, prepend_to_cron_disposition
   end
end



local function find_month(str)
   local possible_pos, possible_endpos, possible_month
   local month_found = false
   local startingpos = 1
   repeat
      possible_pos, possible_endpos, possible_month = string.find(str," ([jfmasond][aepuco][nbrylgptvc])", startingpos)
      if possible_month then
	 if not months[possible_month] then
	    startingpos = possible_endpos
	 else
	    month_found = true
	 end
      else
	 return nil
      end
   until month_found == true
   return { month = months[possible_month] }
end
	 

      
-- Where A and B are associative entities with a 1-1 relation, A is
-- sorted in reverse order.  And, B follows suit as if it were
-- simply an added field of A
local function orderedByKeyLengthBubbleSortReverse(A,B)
   local n = #A
   local swapped = false
   repeat
      swapped = false
      for i=2,n do   -- 0 based is for i=1,n-1 do
	 if A[i-1] < A[i] then
	    A[i-1],A[i] = A[i],A[i-1]
	    B[i-1],B[i] = B[i],B[i-1]
	    swapped = true
	 end
      end
   until not swapped
end


-- Where the first argument is the primary key array to be sorted, and
-- the remaining arguments are arrays that are associative entities
-- with a 1-1 relation with the first array, which are also sorted in
-- accords with the order of the first array.
local function bubbleSortAssociatedArrays(...)
   local A = select(1, ...)
   local n = #A
   local swapped = false
   local t
   repeat
      swapped = false
      for i=2,n do   -- 0 based is for i=1,n-1 do
	 if A[i-1] > A[i] then
	    A[i-1],A[i] = A[i],A[i-1]
	    for j = 2, select("#",...) do
	       t = select(j,...)
	       t[i-1],t[i] = t[i],t[i-1]
	    end
	    swapped = true
	 end
      end
   until not swapped
end

-- Where the first argument is the primary key array to be sorted, and
-- the remaining arguments are arrays that are associative entities
-- with a 1-1 relation with the first array, which are also sorted in
-- accords with the order of the first array.
local function bubbleSortAssociatedArraysReverse(...)
   local A = select(1, ...)
   local n = #A
   local swapped = false
   local t
   repeat
      swapped = false
      for i=2,n do   -- 0 based is for i=1,n-1 do
	 if A[i-1] < A[i] then
	    A[i-1],A[i] = A[i],A[i-1]
	    for j = 2, select("#",...) do
	       t = select(j,...)
	       t[i-1],t[i] = t[i],t[i-1]
	    end
	    swapped = true
	 end
      end
   until not swapped
end

local function __genOrderedByKeyLengthIndex( t )   
   local keylengths = {}
   local orderedIndex = {}
   for key in pairs(t) do
      table.insert( orderedIndex, key )
   end
   for key in pairs(t) do
      table.insert( keylengths, string.len(key))
   end   
   orderedByKeyLengthBubbleSortReverse(keylengths, orderedIndex)   
   return orderedIndex
end

local function orderedByKeyLengthNext(t, state)
    -- Equivalent of the `next' function, but instead of returning the
    --   keys in the alphabetic order, they are in the reverse order
    --   of key length.  We use a temporary ordered key table that is
    --   stored in the table being iterated.
    local key = nil
    --print("orderedByKeyLengthNext: state = "..tostring(state) )
    if not state then
        -- the first time, generate the index
        t.__orderedIndex = __genOrderedByKeyLengthIndex( t )
        key = t.__orderedIndex[1]
    else
        -- fetch the next value
        for i = 1,table.getn(t.__orderedIndex) do
            if t.__orderedIndex[i] == state then
                key = t.__orderedIndex[i+1]
            end
        end
    end

    if key then
        return key, t[key]
    end
    -- no more value to return, cleanup
    t.__orderedIndex = nil
    return
end

local function orderedByKeyLengthPairs(t)
    -- Equivalent of the pairs() function on tables. Allows to iterate
    -- in order
    return orderedByKeyLengthNext, t, nil
end


local function starts_with(str, start)
   return str:sub(1, #start) == start
end

local function ends_with(str, ending)
   return ending == "" or str:sub(-#ending) == ending
end

local function trim5(s)
   return s:match'^%s*(%S+)' or ''
end

-- remove trailing and leading whitespace from string.
-- http://en.wikipedia.org/wiki/Trim_(programming)
local function trim(s)
  -- from PiL2 20.4
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- remove leading whitespace from string.
-- http://en.wikipedia.org/wiki/Trim_(programming)
local function ltrim(s)
  return (s:gsub("^%s*", ""))
end

-- remove trailing whitespace from string.
-- http://en.wikipedia.org/wiki/Trim_(programming)
local function rtrim(s)
  local n = #s
  while n > 0 and s:find("^%s", n) do n = n - 1 end
  return s:sub(1, n)
end

local function remove_extra_spaces(s)
   return s:gsub("%s+"," ")
end

local function str_remove_newline_if_present(s)
   local strlen = #s
   if s:sub(strlen, strlen) == "\n" then
      return s:sub(1,strlen -1)
   else
      return s
   end
end

local function change_all_slashes_to_hyphens(s)
   return s:gsub("/","-")
end

local function str_word_at_pos(s,pos)
   return s:match("%w+",pos)
end

local function array_to_string(array, separator)
   retval = ""
   if not separator then
      separator = " "
   end
   for _,v in ipairs(array) do
      retval = retval..v..separator
   end
   retval = retval:sub(1,-1 - #separator )
   return retval
end

local function str_add_leading_zeros( places, str)
   local leading_zeros = ""
   pp("adding "..places.." zeros")
   for i = 1,places do
      leading_zeros = leading_zeros.."0"
   end
   return leading_zeros..str
end

local function str_is_less_than_p( str1, str2)
   local str1_len = #str1
   local str2_len = #str2
   if str1_len > str2_len then 
      local str_diff = str1_len - str2_len
      str2 = str_add_leading_zeros( str_diff,str2)
   elseif str1_len < str2_len then
      local str_diff = str2_len - str1_len
      str1 = str_add_leading_zeros( str_diff,str1)
   end
   if str1 < str2 then
      return true
   else
      return false
   end
end

local function str_is_less_than_or_equal_to_p( str1, str2)
   local str1_len = #str1
   local str2_len = #str2
   if str1_len > str2_len then 
      local str_diff = str1_len - str2_len
      str2 = str_add_leading_zeros( str_diff,str2)
   elseif str1_len < str2_len then
      local str_diff = str2_len - str1_len
      str1 = str_add_leading_zeros( str_diff,str1)
   end
   if str1 <= str2 then
      return true
   else
      return false
   end
end

local function str_is_greater_than_or_equal_to_p( str1, str2)
   local str1_len = #str1
   local str2_len = #str2
   if str1_len > str2_len then 
      local str_diff = str1_len - str2_len
      str2 = str_add_leading_zeros( str_diff,str2)
   elseif str1_len < str2_len then
      local str_diff = str2_len - str1_len
      str1 = str_add_leading_zeros( str_diff,str1)
   end
   if str1 >= str2 then
      return true
   else
      return false
   end
end

local function ccparse(raw_expr)
    -- This function acts as a wrapper to ccronexpr.c, but doesnt seem
    -- to work properly, taken from
    -- https://github.com/tarantool/cron-parser/blob/master/cron-parser.lua
    local parsed_expr = ffi.new("cron_expr[1]")
    local err = ffi.new("const char*[1]")
    ccronexpr.cron_parse_expr(raw_expr, parsed_expr, err)
    if err[0] ~= ffi.NULL then
        return nil, ffi.string(err[0])
    end
    local lua_parsed_expr = {
        seconds = {},
        minutes = {},
        hours = {},
        days_of_week = nil,
        days_of_month = {},
        months = {}
    }
    for i = 0,7 do
        lua_parsed_expr.seconds[i + 1] = parsed_expr[0].seconds[i]
        lua_parsed_expr.minutes[i + 1] = parsed_expr[0].minutes[i]
    end
    for i = 0,2 do
        lua_parsed_expr.hours[i + 1] = parsed_expr[0].hours[i]
    end
    lua_parsed_expr.days_of_week = parsed_expr[0].days_of_week[0]
    for i = 0,3 do
        lua_parsed_expr.days_of_month[i + 1] = parsed_expr[0].days_of_month[i]
    end
    for i = 0,1 do
        lua_parsed_expr.months[i + 1] = parsed_expr[0].months[i]
    end
    return lua_parsed_expr
end


local function int64_t2String( longlong_number)
   ccronexpr_misc_utils.print_time(longlong_number)
   local target_string_outarg = ffi.new('char[500]')

   ccronexpr_misc_utils.double_long_to_string( target_string_outarg, longlong_number)
   pp(target_string_outarg)
   return target_string_outarg
end

local function ccnext(lua_parsed_expr)
    -- ccronexpr.c wrapper function
    local parsed_expr = ffi.new('cron_expr[1]')
    for i = 0,7 do
        parsed_expr[0].seconds[i] = lua_parsed_expr.seconds[i + 1]
        parsed_expr[0].minutes[i] = lua_parsed_expr.minutes[i + 1]
    end
    for i = 0,2 do
        parsed_expr[0].hours[i] = lua_parsed_expr.hours[i + 1]
    end
    parsed_expr[0].days_of_week[0] = lua_parsed_expr.days_of_week
    for i = 0,3 do
        parsed_expr[0].days_of_month[i] = lua_parsed_expr.days_of_month[i + 1]
    end
    for i = 0,1 do
        parsed_expr[0].months[i] = lua_parsed_expr.months[i + 1]
    end
    local ts = ccronexpr.cron_next(parsed_expr, os.time())

--    return tonumber(ts)
    return int64_t2String(ts)
end

local function ccprev(lua_parsed_expr)
    -- ccronexpr.c wrapper function
    local parsed_expr = ffi.new('cron_expr[1]')
    for i = 0,7 do
        parsed_expr[0].seconds[i] = lua_parsed_expr.seconds[i + 1]
        parsed_expr[0].minutes[i] = lua_parsed_expr.minutes[i + 1]
    end
    for i = 0,2 do
        parsed_expr[0].hours[i] = lua_parsed_expr.hours[i + 1]
    end
    parsed_expr[0].days_of_week[0] = lua_parsed_expr.days_of_week
    for i = 0,3 do
        parsed_expr[0].days_of_month[i] = lua_parsed_expr.days_of_month[i + 1]
    end
    for i = 0,1 do
        parsed_expr[0].months[i] = lua_parsed_expr.months[i + 1]
    end
    local ts = ccronexpr.cron_prev(parsed_expr, os.time())

--    return tonumber(ts)
    return int64_t2String(ts)

end

 


-- This is a pattern_matching_function thats passed as an argument to merge_stuff_following_keywords()
local function in_future_time_parser(str, starting_tbl)
   -- There are 3 kinds of duration cases. The first case is that the duration starts at now, the return value being the table at the end of the duration.  The 2nd is that it starts after a variable duration in the future, in which case starting_tbl should be empty and the return value is the table at the end of said duration.   The 3rd is that it starts at a future date, for a variable duration, the return value being the table at the end of the duration.
   pp("in_future_time_parser(" .. str ..",)")
   pp(ins(starting_tbl))
   str = str:gsub("%s+"," ")  -- remove_extra_spaces(str)
--   str = trim5(str)
   str = str:lower()
   str = " " .. str .. " "
   local starting
   if not is_empty(starting_tbl) then
      starting = os.time(starting_tbl)
   else
      pp("starting table, passed to in_future_time_parser, was empty")
      starting = os.time()
   end 
   local weeks = str:match(" (%d%d?%d?) ?we?e?ks? ")
   if weeks then pp(weeks.." weeks"); weeks = tonumber(weeks) else weeks = 0 end
   local days = str:match(" (%d%d?%d?) ?da?y?s? ")
   if days then pp(days.."days"); days = tonumber(days) else days = 0 end
   local mins = str:match(" (%d%d?%d?) ?mi?n?u?t?e?s? ")
   if mins then pp(mins.."mins"); mins = tonumber(mins) else mins = 0 end
   local hours = str:match(" (%d%d?%d?%.?%d?%d?) ?ho?u?r?s? ")
   if hours then pp(hours.."hours"); hours = tonumber(hours) else hours = 0 end
   return os.date("*t", (weeks * 604800) + (days * 86400) + (hours * 3600) + (mins * 60) + starting )
end


-- This is a pattern matching function, to be supplied as an argument
-- to the function merge_stuff_following_keyword(), and returns the
-- date table of a datetime string, str.  str should be something
-- resembling an RFC2822 string, such as "Fri, 25 Mar 2016 16:24:56
-- +0100", or an iso8601 string, such as "2019-12-30T23:11:10+0800,
-- but various formats are accepted except the forms DD-MM-YYYY and
-- YYYY-DD-MM.  Also, hyphens and forward slashes are interchangeable.
local function variant_date_parser( str)
   pp("variant_date_parser(" .. str .. ")")
   local current_time = os.date("*t",os.time())
   local isdst = current_time.isdst
   local tmp_partial_date = {}


   local date_patterns_tbl = setmetatable({
      [" (%d%d%d%d)%-(%d%d)%-(%d%d) "] = function(str2)
	 local year,month,day = str2:match(" (%d%d%d%d)%-(%d%d)%-(%d%d) ")
	 if not (year and month and day) then
	    return nil
	 end
	 year = tonumber(year)
	 month = tonumber(month)
	 day = tonumber(day)
	 if year < 1900 or year > 2038 or month > 12 or day > 31 then
	    return nil
	 end
	 return { year = year, month = month, day = day }
      end,
      [" ([1234])[snrt][tddh] ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])"] = function(str2)
	 local ordinal, wday, month = str2:match(" ([1234])[snrt][tddh] ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])")
	 if not (ordinal and wday and month) then
	    return nil
	 end
	 ordinal = tonumber(ordinal)
	 wday = dow[wday]
	 month = months[month]
	 if not (ordinal and wday and month) then
	    return nil
	 end
	 return date_of_the_nth_wday_of_m(ordinal,wday,month)
end,
      [" last ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])"] = function(str2)
	 local ordinal, wday, month = str2:match(" last ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])")
	 if not (ordinal and wday and month) then
	    return nil
	 end
--	 ordinal = tonumber(ordinal)
	 wday = dow[wday]
	 month = months[month]
	 if not (wday and month) then
	    return nil
	 end
	 pp("looking for")
	 pp(str2)
	 return date_of_the_nth_wday_of_m("last",wday,month)
end,
      [" 2nd to last ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])"] = function(str2)
	 local ordinal, wday, month = str2:match(" 2nd to last ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])")
	 if not (ordinal and wday and month) then
	    return nil
	 end
--	 ordinal = tonumber(ordinal)
	 wday = dow[wday]
	 month = months[month]
	 if not (wday and month) then
	    return nil
	 end
	 return date_of_the_nth_wday_of_m("2nd to last",wday,month)
end,

     [" tomorrow "] = function(str2)
	if str2:match(" tomorrow ") then
	   local tomorrow = os.time() + 60*60*24
	   return { month = os.date("%m", tomorrow), year = os.date("%Y", tomorrow), day = os.date("%d",tomorrow) }
	end
     end,
     [" now "] = function(str2)
	if str2:match(" now ") then
	   local now = os.time()
	   return { month = os.date("%m", now), year = os.date("%Y", now), day = os.date("%d",now), now = true }
	end
     end,

     [" day after tomorrow "] = function(str2)
	if str2:match(" day after tomorrow ") then
	   local DAtomorrow = os.time() + 60*60*24*2
	   return { month = os.date("%m", DAtomorrow), year = os.date("%Y", DAtomorrow), day = os.date("%d",DAtomorrow) }
	end
     end,

     [" today "] = function(str2)
	if str2:match(" today ") then
	   
	   return { month = os.date("%m"), year = os.date("%Y"), day = os.date("%d") }
	end
     end,     
      [" second to last ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])"] = function(str2)
	 local ordinal, wday, month = str2:match(" 2nd to last ([mtwtfss][ouehrau][neduitn]) of ([jfmasond][aepuco][nbrylgptvc])")
	 if not (ordinal and wday and month) then
	    return nil
	 end
--	 ordinal = tonumber(ordinal)
	 wday = dow[wday]
	 month = months[month]
	 if not (wday and month) then
	    return nil
	 end
	 return date_of_the_nth_wday_of_m("2nd to last",wday,month)
end,



      [" (%d%d) (%l%l%l) (%d%d%d%d) "] = function(str2)
	 local day,month,year = str2:match(" (%d%d) (%l%l%l) (%d%d%d%d) ")
	 if not (day and month and year) then
	    return nil
	 end
	 day = tonumber(day)
	 month = months[month]
	 year = tonumber(year)
	 if day > 31 or not month or year < 1900 or year > 2038 then
	    return nil
	 end
	 return { day = day, month = month, year = year }
      end,
      [" (%d%d?)%-(%d%d?) "] = function(str2)
	 local month,day = str2:match(" (%d%d?)%-(%d%d?) ")
	 if not (month and day) then
	    return nil
	 end
	 year = tonumber(os.date("%Y"))   -- assume this year
	 month = tonumber(month)
	 day = tonumber(day)
	 if month > 12 or day > 31 then
	    return nil
	 end
	 return { year = year, month = month, day = day }
      end,
      [" (%d%d?)th "] = function(str2)
	 local day = str2:match(" (%d%d?)th ")
	 if not day then
	    return nil
	 end
	 day = tonumber(day)
	 if day > 31 then
	    return nil
	 end
	 return { day = day }
      end,
      
      [" 1st "] = function(str2)
	 if str2:match(" 1st ") then
	    return { day = 1 }
	 else
	    return nil
	 end
      end,
      [" 2nd "] = function(str2)
	 if str2:match(" 2nd ") then
	    return { day = 2 }
	 else
	    return nil
	 end	 
      end,
      [" 3rd "] = function(str2)
	 if str2:match(" 3rd ") then
	    return { day = 3 }
	 else
	    return nil
	 end
      end
					  } , { __index = function(s,k) return function(str2) return nil end end} )

   
   local time_patterns_tbl = setmetatable({
      ["t?(%d%d?):(%d%d):(%d%d)[ ]?([%+%-])(%d%d)(%d%d)"] = function(str2)
	 local hour,min,second,sign,tzhour,tzmin = str2:match("t?(%d%d?):(%d%d):(%d%d)[ ]?([%+%-])(%d%d)(%d%d)")
	 if not (hour and min and second and sign and tzhour and tzmin) then
	    return nil
	 end
	 
	 local tmp = 1
	 if sign == "-" then
	    tmp = -1
	 end
	 hour = tonumber(hour)
	 min = tonumber(min)
	 second = tonumber(second)
	 local tm_gmtoff = (tonumber(tzhour)*3600 + tonumber(tzmin))*tmp
	 if hour > 23 or min > 59 or second > 59 then
	    return nil
	 else	    
	    return { hour = hour, min = min, second = second, tm_gmtoff = tm_gmtoff }
	 end
      end,

      ["(%d%d?):(%d%d)[ ]?([%+%-])(%d%d)(%d%d)"] = function(str2)
	 local hour,min,sign,tzhour,tzmin = str2:match("(%d%d?):(%d%d)[ ]?([%+%-])(%d%d)(%d%d)")
	 local tmp = 1
	 if not (hour and min and sign and tzhour and tzmin) then
	    return nil
	 end	 
	 if sign == "-" then
	    tmp = -1
	 end
	 hour = tonumber(hour)
	 min = tonumber(min)
	 local tm_gmtoff = (tonumber(tzhour)*3600 + tonumber(tzmin))*tmp
	 if hour > 23 or min > 59  then
	    return nil
	 else	    
	    return { hour = hour, min = min, tm_gmtoff = tm_gmtoff }
	 end
      end,
      
      ["(%d%d?):(%d%d) ?p[m ]"] = function(str2)
	 local hour,min = str2:match("(%d%d?):(%d%d) ?p[m ]")
	 if not (hour and min)  then
	    return nil
	 end	
	 local add_meridiem = 12
	 local tmp = 1
	 hour = tonumber(hour) 
	 min = tonumber(min)
	 if hour > 12 or min > 59  then
	    return nil
	 elseif	hour == 12 then
	    add_meridiem = 0
	 end	 	    
	 return { hour = hour + add_meridiem, min = min }
       end,
      

      ["(%d%d?):(%d%d) ?a[m ]"] = function(str2)
	 local hour,min = str2:match("(%d%d?):(%d%d) ?a[m ]")
	 if not (hour and min)  then
	    return nil
	 end
	 local tmp = 1
	 hour = tonumber(hour) 
	 min = tonumber(min)
	 if hour > 12 or min > 59  then
	    return nil
	 elseif	hour == 12 then
	    hour = 0
	 end	 	    
	 return { hour = hour, min = min }
       end,
            
      ["(%d%d?) o'?clock p[m ]"] = function(str2)
	 local hour = str2:match("(%d%d?) o'?clock p[m ]")
	 if not hour  then
	    return nil
	 end

	 local add_meridiem = 12
	 hour = tonumber(hour)
	 if hour < 1 or hour > 12 then
	    return nil
	 elseif hour == 12 then
	    add_meridiem = 0
	 end	 
	 return { hour = hour + add_meridiem }	 
      end,
      
      ["(%d%d?) o'?clock a[m ]"] = function(str2)
	 local hour = str2:match("(%d%d?) o'?clock a[m ]")
	 if not hour  then
	    return nil
	 end
	 hour = tonumber(hour)
	 if hour < 1 or hour > 12 then
	    return nil
	 elseif hour == 12 then
	    hour = 0
	 end	 
	 return { hour = hour } 
      end,

      ["(%d%d?):(%d%d)"] = function(str2)
	 local hour,min = str2:match("(%d%d?):(%d%d)")
	 if not (hour and min)  then
	    return nil
	 end
	 local tmp = 1
	 hour = tonumber(hour) 
	 min = tonumber(min)
	 if hour > 12 or min > 59  then
	    return nil
	 elseif	hour == 12 then
	    hour = 0
	 end	 	    
	 return { hour = hour, min = min }
      end,

      ["(%d%d?) ?p[m ]"] = function(str2)
	 local hour = str2:match("(%d%d?) ?p[m ]")
	 if not hour  then
	    return nil
	 end
	 local add_meridiem = 12
	 hour = tonumber(hour)
	 if hour < 1 or hour > 12 then
	    return nil
	 elseif hour == 12 then
	    add_meridiem = 0
	 end	 
	 return { hour = hour + add_meridiem }	 
      end,
      
      ["(%d%d?) ?a[m ]"] = function(str2)
	 local hour = str2:match("(%d%d?) ?a[m ]")
	 if not hour  then
	    return nil
	 end
	 hour = tonumber(hour)
	 if hour < 1 or hour > 12 then
	    return nil
	 elseif hour == 12 then
	    hour = 0
	 end	 
	 return { hour = hour } 
      end,

      ["@ (%d%d?) ?a?a+m?"] = function(str2)
	 local hour = str2:match("@ (%d%d?) ?a?a+m?")
	 if not hour then
	    return nil
	 end
	 hour = tonumber(hour)
	 if hour < 1 or hour > 12 then
	    return nil
	 elseif hour == 12 then
	    hour = 0
	 end	 
	 return { hour = hour } 
      end,

      [" at (%d%d?) ?a?a+m?"] = function(str2)
	 local hour = str2:match(" at (%d%d?) ?a?a+m?")
	 if not hour then
	    return nil
	 end
	 hour = tonumber(hour)
	 if hour < 1 or hour > 12 then
	    return nil
	 elseif hour == 12 then
	    hour = 0
	 end	 
	 return { hour = hour } 
      end
					  }, {__index=function(s,k) return function(str2) return nil end end})

   str = str:gsub("%s+"," ")  -- remove_extra_spaces(str)
--   str = trim5(str)
   str = str:match('^%s*(.*%S)') or ''  
   str = str:lower()

   str = str:gsub("/","-")
 --  str = trim5(str)
   str = " " .. str .. " "
   -- search string for month written out
   local returnval_tbl = {}
   tmp_partial_date = find_month(str)
   if tmp_partial_date then
      tblShallowMerge(returnval_tbl,tmp_partial_date)
   end
   -- search string for day of the week written out
   dow_written_out  = find_dow(str)
   if dow_written_out then
      returnval_tbl.dow_written_out = dow_written_out
   end
   -- search string for recurring day of the week written out
   -- dow_recurring_written_out = find_dow_recurring(str) 
   -- if dow_recurring_written_out then
   --    returnval_tbl.dow_recurring_written_out = dow_recurring_written_out
   -- end
   

   -- seach date patterns
   for _,v in orderedByKeyLengthPairs(date_patterns_tbl) do
      tmp_partial_date =  v(str)
      if tmp_partial_date and type(tmp_partial_date) == "table" then
	 for i,j in pairs(tmp_partial_date) do
	    returnval_tbl[i] = j
	 end
	 break
      end
   end
   -- search time patterns
   for _,v in orderedByKeyLengthPairs(time_patterns_tbl) do
      tmp_partial_date =  v(str)
      if tmp_partial_date and type(tmp_partial_date) == "table" then
	 for i,j in pairs(tmp_partial_date) do
	    returnval_tbl[i] = j
	 end
	 break
      end
   end
   return returnval_tbl
end


--  Each entry in the crontab might contain one or two of the
--  following recognized tags: a tag of #ONHOLD#, optionally including
--  the md5sum of its instigator, appearing before the schedule
--  portion of an entry, and a tag of #TMP appearing at the very end
--  of an entry.  The tags can be altered by changing the variables
--  onhold_token tmp_token, respectively.
local function get_cron_jobs()
   local tmphandle = io.popen("crontab -l 2>" .. errormsg_file)
--debug   local tmphandle = io.popen("cat crontable") --debug
   local result = tmphandle:read("*a")
   if not result then
      return nil
   end	   
   tmphandle:close()

   
   local field1, field2, field3, field4, field5, field6, onhold_key, onhold_key2
   local jobnum = 0
   local cron = {}
   cron.cron_all = {}
   cron.cronjobs = {}
   cron.cronjob_md5sumhexa = {}
   cron.cronjob_md5sumhexa_to_linenum = {}
   cron.cronjob_md5sumhexa_to_jobnum = {}
   cron.cronjob_md5sumhexa_to_cronline = {}  --debug
   cron.cronjob_jobnum_to_linenum = {}
   cron.cronjob_schedules = {}
   cron.cronjob_dispositions = {}
   cron.cronjob_line_numbers = {}
   cron.cronjob_smart_device_client_cmds = {}
   cron.cronjob_smart_device_client_cmds_cmd = {}
   cron.cronjob_smart_device_client_cmds_line_numbers = {}
   cron.onholdjobs = {}
   cron.onholdjob_md5sumhexa = {}
   cron.onholdjob_schedules = {}
   cron.onholdjob_dispositions = {}
   cron.onholdjob_line_numbers = {}
   cron.onholdjob_key = {}
   cron.tmp_md5sumhexa = {}
   cron.tmp_schedules = {}
   cron.tmp_dispositions = {}
   cron.tmp_line_numbers = {}
   cron.blanklines = {}
   cron.blanklines_line_numbers = {}
   result = split(result, "\n")

   local line_num
   for k,v in ipairs(result) do   
      line_num = k
      if not v:match'^%s*(%S+)' then	
	 table.insert( cron.blanklines,v)
	 table.insert( cron.blanklines_line_numbers,k)
      end

      table.insert( cron.cron_all,v)
--      v = v:match('^%s*(.*%S)') or ''     
      v = trim(v)
      if not v:match("^#") and v ~= '' then

	 field1, field2, field3, field4, field5, field6 = v:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
	 -- note: when calling the ccronexpr function, field 1 must be seconds not minutes, so we must add a seconds field so ccronexpr.c doesnt crash

	 if field6 then  
	    pp("field6 = "..field6)
	    if starts_with(field6,smart_device_client_program) then 
	       
	       table.insert(cron.cronjob_smart_device_client_cmds,v)
	       table.insert(cron.cronjob_smart_device_client_cmds_line_numbers,line_num)
	       table.insert(cron.cronjob_smart_device_client_cmds_cmd,field6:match(smart_device_client_program.."%s+(%S+)"))
	    end
	    jobnum = jobnum + 1
	    table.insert(cron.cronjob_jobnum_to_linenum,k)
	    table.insert( cron.cronjobs,v)

	    table.insert( cron.cronjob_line_numbers, line_num)
	    table.insert( cron.cronjob_schedules, field1.." "..field2.." "..field3.." "..field4.." "..field5)
	    if field6:sub(-#tmp_token,-1) == tmp_token then
	       local actual_line = v:sub(1,-#tmp_token-1)
	       local md5sumhexa_val = md5.sumhexa( actual_line)
	       table.insert( cron.cronjob_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert( cron.cronjob_md5sumhexa, md5.sumhexa( v:sub(1,-#tmp_token-1)))
	       cron.cronjob_md5sumhexa_to_linenum [md5.sumhexa( v:sub(1,-#tmp_token-1))] = line_num
	       cron.cronjob_md5sumhexa_to_cronline[md5.sumhexa( v:sub(1,-#tmp_token-1))] = v:sub(1,-#tmp_token-1) 
	       table.insert(cron.tmp_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert(cron.tmp_schedules, field1.." "..field2.." "..field3.." "..field4.." "..field5)
	       table.insert(cron.tmp_line_numbers, line_num)

	    else
	       table.insert( cron.cronjob_dispositions, field6)
	       table.insert( cron.cronjob_md5sumhexa, md5.sumhexa(v))
	       -- table.insert( cron.cronjob_schedules, field1.." "..field2.." "..field3.." "..field4.." "..field5) -- nm, ranged schedules cannot have an epoch
	       cron.cronjob_md5sumhexa_to_linenum [ md5.sumhexa(v)] = line_num
	       cron.cronjob_md5sumhexa_to_cronline[ md5.sumhexa(v)] = v
	    end
	 end
      else  -- the cron statement begins with a comment
	 onhold_key, onhold_key2, field1, field2, field3, field4, field5, field6 = v:match(onhold_token.."%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
	 if onhold_key then pp("onhold_key="..onhold_key) end
	 if onhold_key2 then pp("onhold_key2="..onhold_key2) end
	 if field1 then pp("onhold field1="..field1) end
	 if field6 then pp("onhold field6="..field6) end
	 -- note: field 1 is actually minutes, not seconds, so we must add a seconds field before calling ccparse() so ccronexpr.c doesnt crash
	 if field6 then
	    local onhold_token_begin, onhold_token_end = v:find(onhold_token)
	    
	    table.insert( cron.onholdjobs,v)
	    cron.onholdjob_key[onhold_key]=#cron.onholdjobs
	    table.insert( cron.onholdjob_line_numbers, line_num)
	    table.insert( cron.onholdjob_schedules, field1.." "..field2.." "..field3.." "..field4.." "..field5)
	    if field6:sub(-#tmp_token,-1) == tmp_token then  -- #ON HOLD#  and #TMP
	       local md5sum = md5.sumhexa(v:sub(onhold_token_end+1,-#tmp_token-1))
	       table.insert( cron.onholdjob_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert( cron.onholdjob_md5sumhexa, md5sum )
	       table.insert( cron.cronjob_md5sumhexa, md5sum )

	       table.insert(cron.tmp_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert(cron.tmp_schedules, field1.." "..field2.." "..field3.." "..field4.." "..field5)
	       table.insert( cron.tmp_md5sumhexa, md5sum )
	       table.insert(cron.tmp_line_numbers, line_num)
	       -- cron.onholdjob_md5sumhexa_to_linenum [md5.sumhexa( v:sub(1,-#tmp_token-1))] = line_num
	       -- cron.onholdjob_md5sumhexa_to_cronline[md5.sumhexa( v:sub(1,-#tmp_token-1))] = v:sub(1,-#tmp_token-1) 
	       
	    else                   -- just #ON HOLD#
	       local md5sum = md5.sumhexa(v:sub(onhold_token_end+1,-1))
	       table.insert( cron.onholdjob_dispositions, field6)
	       table.insert( cron.onholdjob_md5sumhexa, md5sum )
	       table.insert( cron.cronjob_md5sumhexa, md5sum)

	    end
	 end
	 
      end
   end  -- end for
   cron.cronjob_md5sumhexa_to_jobnum = make_reverse_lookup_table(cron.cronjob_md5sumhexa)
   cron.onholdjob_md5sumhexa_reverselookup = make_reverse_lookup_table(cron.onholdjob_md5sumhexa)
   pp(ins(cron))
   return cron
end  -- get_cron_jobs() ends here --


local function tblDeleteLine(t,d)
   if not d then 
      return t
   end
   local new_table = {}
   for k,v in ipairs(t) do
      if k ~= d then 
	 table.insert(new_table,v)
      end
   end
   return new_table
end

local function tblDeleteLines(t,d)
   if not d or is_empty(d) then
      return t
   end
   pp("deleting "..#d.." lines")
   local line = 1
   local new_table = {}
   local setd = {}
   for _, l in ipairs(d) do
      setd[l] = true
   end
   for k,v in ipairs(t) do
      if not setd[k] then 
	 table.insert(new_table,v)
      end
   end
   return new_table
end

-- This function strips away all the lines out of an array, passed as
-- first parameter, that consist of "", that are preceeded by more
-- than n number of like lines.  The return value will be a table with
-- the same content, but that will not have more than n consecutive
-- blank lines anywhere in it.
local function tblOnly_allow_n_consecutive_blank_lines( tblInput, n )
   local stackLast_line = {}
   local new_table = {}
   n=n+1
    
   local function last_n_lines_of_tbl_are_not_blank_lines ( )
      local stack_size = #stackLast_line
      if stack_size < n then
	 return true 
      end
      for i = 0, n - 1 do
	 local strstack = stackLast_line[stack_size-i]
	 if strstack ~= nil and strstack ~= "" then
	    return true
	 end
      end
      return false
   end
   
   for k,v in ipairs( tblInput ) do
      table.insert ( stackLast_line, v)
      if last_n_lines_of_tbl_are_not_blank_lines( ) then
	 table.insert( new_table, v)
      end
   end
   return new_table
end
   
local function array_to_multi_line_string_escaping_single_quotes(array)
   local multi_line_string = ""
   for _,line in ipairs(array) do
      local quote_pos_not_found = true
      local quote_pos = 0
      while quote_pos_not_found do
	 pp("looking for "..quote_pos)
	 quote_pos = line:find("'", quote_pos+1)
	 if quote_pos then
	    if quote_pos == 1 then
	       line = "\\"..line
	    elseif line:sub(quote_pos-1,quote_pos-1) ~= "\\" then
	       line = line:sub(1,quote_pos-1).."\\"..line:sub(quote_pos,-1)	       
	    end
	 else
	    quote_pos_not_found = false
	    
	 end
      end
      multi_line_string = multi_line_string..line.."\n"
   end
   return multi_line_string
end

-- ok someday I'll get this function to work properly without having to write to an intermediary file
local function DOESNTWORKsubmit_crontab(tblCron)
--  cmd = [[bash -c "echo -e ']]..array_to_multi_line_string_escaping_single_quotes(tbl)..[['" > testg8.txt]]   --works only when there are no single quote characters in tbl; cant seem to escape them

--      local newcron_cmd = [[ bash -c 'echo -e ]]..string.format("%q",table.concat(tblCron,"\n"))..[[ | crontab -']]
--   local cron_table_string = array_to_multi_line_string_escaping_single_quotes(tblCron)
   local newcron_cmd = [[bash -c "echo -e ']]..array_to_multi_line_string_escaping_single_quotes(tblCron)..[=[' > crontable"]=]  --debug
   pp("newcron_cmd:")
   pp(ins(newcron_cmd)) --debug
  
--   local newcron_cmd = [[ bash -c "echo -e ]]..string.format("%q",table.concat(tblCron,"\n"))..[[ > crontable"]]  --debug
   os.execute(newcron_cmd)      

end

local function submit_crontab(array)
   if isdir("/tmp") then
      array = tblRemove_duplicates_that_are_not_blank_or_comments(array)
      array = tblOnly_allow_n_consecutive_blank_lines(array,2)
      pp("now writing crontab")
      print_current_datetime()
      pp(ins(array)) --debug
      local tmpfilename = randomString(10)
      local fileh = assert(io.open("/tmp/"..tmpfilename,"w"))
--debug            local fileh = io.open("/tmp/crontable","w") --debug
      for _,v in ipairs(array) do
	 fileh:write(v)
	 fileh:write("\n")
      end
      fileh:close()
      assert(os.execute("cat /tmp/"..tmpfilename.." | crontab -"))
      os.remove("/tmp/"..tmpfilename)
   end
end


local function hold_job (cj, jobnum, md5sums_of_hold_instigator )
   if not md5sums_of_hold_instigator then
      md5sums_of_hold_instigator = ""
   end
   local cronlinenum = cj.cronjob_line_numbers[jobnum]
   local cronline = cj.cron_all[cronlinenum]
   cronline = "#ONHOLD "..md5sums_of_hold_instigator.." #"..cronline
--   cj.cron_all[onholdjob_linenum] = cronline
   cj.cron_all[cronlinenum] = cronline
end

local function hold_all()
   cj = get_cron_jobs()
   for i in #cj.cronjobs do
      hold_job(cj,i)
   end
   submit_cron(cj.cron_all)
end

local function unhold_job( cj, md5sum )

--   local onholdjobnum = cj.onholdjob_key[md5sum]
   local onholdjobnum = cj.onholdjob_md5sumhexa_reverselookup[md5sum]
   if onholdjobnum then
      local onholdjob_linenum = cj.onholdjob_line_numbers[onholdjobnum]
      local cronline =  cj.cron_all[onholdjob_linenum]
      
      local onhold_token_begin, onhold_token_end = cronline:find(onhold_token)
      cronline = cronline:sub(onhold_token_end + 1,-1)
      cj.cron_all[onholdjob_linenum] = cronline

   end
end

local function unhold_all_jobs()
   local cj = get_cron_jobs()
   local no_held_jobs_found = true
   for _,onholdjob_linenum in ipairs(cj.onholdjob_line_numbers) do
      local cronline =  cj.cron_all[onholdjob_linenum]     

      local onhold_token_begin, onhold_token_end = cronline:find(onhold_token)
      if onhold_token_end then

	 no_held_jobs_found = false
	 cronline = cronline:sub(onhold_token_end + 1,-1)
      pp(cronline)
	 cj.cron_all[onholdjob_linenum] = cronline

      end
   end
   if not no_held_jobs_found then
      submit_crontab(cj.cron_all)
   end
end

local function ccnext2(schedule)
   if schedule then
      local handle_misc = io.popen('./cron_next_epoch_time_this_line_should_execute "'..schedule..'"')
      local next_schedule = handle_misc:read("*a")
      handle_misc:close()
      return next_schedule
   end
      
end

-- Converts epoch time, which is seconds elapsed since Jan 1st 1970, to a string recognized by crond
local function epoch_to_schedule(epoch)
   local tbl = os.date("*t",epoch)
   return tbl.min.." "..tbl.hour.." ".. tbl.day.." ".. tbl.month.." *"
end

-- Converts a line from a crontab to epoch time, which is seconds elapsed since Jan 1st 1970.
local function schedule_to_epoch(schedule)
   local tbl = {}
   local now = os.date("*t")
   local field1, field2, field3, field4, field5, field6 = schedule:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
   tbl.min, tbl.hour, tbl.day, tbl.month, tbl.wday = field1, field2, field3, field4, field5
   tbl.year = now.year
   
   return tostring(os.time(tbl))
end

local function linenum_of_clear_schedule(cj,md5sum_begin,md5sum_end)
   for k,v in ipairs(cj.cronjob_smart_device_client_cmds_cmd) do
      if md5sum_begin and v == "clear" and cj.cronjob_smart_device_client_cmds[k]:match(md5sum_begin) then
	 return cj.cronjob_smart_device_client_cmds_line_numbers[k]
      end
      if md5sum_end and v == "clear" and cj.cronjob_smart_device_client_cmds[k]:match(md5sum_end) then
	 return cj.cronjob_smart_device_client_cmds_line_numbers[k]
      end
   end
   return nil
end

local function linenum_of_unhold_delete(cj,unhold_str,delete_str)
   for k,v in ipairs(cj.cronjob_smart_device_client_cmds_cmd) do
      if unhold_str and v == "unhold" and cj.cronjob_smart_device_client_cmds[k]:match(unhold_str) then
	 pp("unhold found at line "..cj.cronjob_smart_device_client_cmds_line_numbers[k])
	 return cj.cronjob_smart_device_client_cmds_line_numbers[k]
      end
      if delete_str and v == "delete" and cj.cronjob_smart_device_client_cmds[k]:match(delete_str) then
	 pp("delete found at line "..cj.cronjob_smart_device_client_cmds_line_numbers[k])
	 return cj.cronjob_smart_device_client_cmds_line_numbers[k]
      end
   end
end

-- todo: look at onholdjobs also, because they might be unheld during the
-- given time frame, specifically look at any unhold dispositions
local function clear_schedule_for(md5sum_begin,md5sum_end)
--   local md5sum_begin, md5sum_end = md5sums_string:match("(%x+)%s*[, ]?%s*(%x+)")
   local cj = get_cron_jobs()
   if cj then
      local job_linenumbers_to_be_held = {}
      local jobnum = cj.cronjob_md5sumhexa_to_jobnum[md5sum_begin]
      if not jobnum then
	 return
      end
      local disposition_begin = cj.cronjob_dispositions[jobnum]
      local disposition_action_begin = dispositions_to_action[disposition_begin]
      local device_begin = dispositions_to_device[disposition_begin]

--debug   local parsed_schedule_begin = ccparse("0 "..cj.cronjob_schedules[jobnum])
--   pp(ins(cj))
      pp"clearing schedule for md5sum_begin:"
      pp(md5sum_begin)
      pp'md5sum_end:'
      pp(md5sum_end)
      pp'jobnum:' 
      pp(jobnum)
      pp(cj.cronjob_schedules[jobnum])
--      local clear_begin = str_remove_newline_if_present(ccnext2(cj.cronjob_schedules[jobnum]))
      local clear_begin = schedule_to_epoch(cj.cronjob_schedules[jobnum])


      pp'clear_begin epoch'
      pp(clear_begin)

      local jobnum = cj.cronjob_md5sumhexa_to_jobnum[md5sum_end]
      if not jobnum then
	 return
      end

--      local device_end = dispositions_to_device[cj.cronjob_dispositions[jobnum]]
      local disposition_end = cj.cronjob_dispositions[jobnum]
      local disposition_action_end = dispositions_to_action[disposition_end]
      local device_end = dispositions_to_device[disposition_end]

--debug   local parsed_schedule_end = ccparse("0 "..cj.cronjob_schedules[jobnum])
--debug   local clear_begin = ccnext(parsed_schedule_begin)
--debug   local clear_end = ccnext(parsed_schedule_end)
      pp(cj.cronjob_schedules[jobnum])
      local schedule_end = cj.cronjob_schedules[jobnum]
--      local clear_end = str_remove_newline_if_present(ccnext2(schedule_end))
      local clear_end = schedule_to_epoch(schedule_end)
      pp'clear_end epoch'
      pp(clear_end)
      schedule_end = epoch_to_schedule(tonumber(clear_end)+60)
      pp'schedule_end'
      pp(schedule_end)
      local held = {}
      pp("check conflict range-")
      pp("clear_begin:")
      pp(ins(clear_begin))
      pp("clear_end:")
      pp(ins(clear_end))     
      for k,v in ipairs(cj.cronjob_dispositions) do
	 if v == disposition_end then
	    --debug	 local parsed_possible_conflict = ccparse("0 "..cj.cronjob_schedule[k])
--debug	 local possible_conflict_begin = ccnext(parsed_possible_conflict)
	    pp(cj.cronjob_schedules[k])
	    local possible_conflict_begin = str_remove_newline_if_present(ccnext2(cj.cronjob_schedules[k]))
	    pp("possible_conflict_begin:")
	    pp(possible_conflict_begin)
	    if str_is_greater_than_or_equal_to_p(possible_conflict_begin,clear_begin) and str_is_less_than_or_equal_to_p(possible_conflict_begin,clear_end) and cj.cronjob_md5sumhexa[k] ~= md5sum_begin and cj.cronjob_md5sumhexa[k] ~= md5sum_end  then
	       pp("hold job:")
	       pp(md5sum_begin)
	       hold_job(cj,k,md5sum_begin.." "..md5sum_end)
	       table.insert(held, cj.cronjob_md5sumhexa[k])
	       pp(ins(held))

	    end
	 end
      end
      local held_items = array_to_string(held)
      pp("held_items:")
      pp(ins(held))
      pp(held_items)
      pp("a couple items to delete:")
      pp(md5sum_begin)
      pp(md5sum_end)
      if held_items then
	 table.insert(cj.cron_all,schedule_end.." "..smart_device_client_program.." unhold "..held_items.." delete "..md5sum_begin.." "..md5sum_end)
      else
	 table.insert(cj.cron_all,schedule_end.." "..smart_device_client_program.." delete "..md5sum_begin.." "..md5sum_end)
      end	
      local line_num_of_clear = linenum_of_clear_schedule(cj,md5sum_begin,md5sum_end)
      
      if line_num_of_clear then
	 cj.cron_all = tblDeleteLine(cj.cron_all,line_num_of_clear)
	 pp("deleting line_num_of_clear:")
	 pp(line_num_of_clear)
      end
      submit_crontab(cj.cron_all)     
   end
end


local function unhold_jobs_delete_jobs(unhold_str,delete_str)
   pp("calling unhold_jobs_delete_jobs")
   pp'unhold:'
   pp(unhold_str)
   pp'delete:'
   pp(delete_str)
   local cj = get_cron_jobs()
   for md5sum in unhold_str:gmatch("%w+") do
      unhold_job(cj, md5sum)
   end
   local jobs_to_delete_linenums = {}
   for md5sum in delete_str:gmatch("%w+") do
      table.insert(jobs_to_delete_linenums, cj.cronjob_md5sumhexa_to_linenum[md5sum])
      pp("deleting md5sum at line num:")
      pp(md5sum)
      pp(cj.cronjob_md5sumhexa_to_linenum[md5sum])

   end

   -- bubbleSortAssociatedArraysReverse(jobs_to_delete_linenums)
   -- for _,v in ipairs(jobs_to_delete_linenums) do
   --    table.remove(cj.cron_all,v)
   -- end
   local line_num_of_unhold_delete = linenum_of_unhold_delete(cj,unhold_str,delete_str)
      
   if line_num_of_unhold_delete then
      pp("deleting line_num_of_unhold_delete:")
      pp(line_num_of_unhold_delete)
      table.insert(jobs_to_delete_linenums, line_num_of_unhold_delete)
   end
   cj.cron_all = tblDeleteLines(cj.cron_all,jobs_to_delete_linenums)
   submit_crontab(cj.cron_all)   
end
   

local function delete_old_cron_jobs()
   local cron = get_cron_jobs()
   local cron_to_be_checked = {}
   local cron_line_numbers_to_be_deleted = {}
   local cron_line_numbers_not_to_be_deleted = {}
   local cron_text_to_be_deleted = {}
   local cron_text_not_to_be_deleted = {}
   local now = os.time()
   local cut_off_date = now - 60*60*24*2  -- delete all #TMP thats more than 2 days old
   pp("cut_off_date:")
   pp(cut_off_date)
   for k,v in ipairs(cron.tmp_schedules) do
      local epoch_time = tonumber(schedule_to_epoch(v))
      pp("epoch_time:")
      pp(epoch_time)
      if epoch_time < cut_off_date then
	 table.insert(cron_line_numbers_to_be_deleted, cron.tmp_line_numbers[k])
      end
   end
   pp("cron_line_numbers_to_be_deleted:")
   pp(ins(cron_line_numbers_to_be_deleted))
   local newcron = tblDeleteLines(cron.cron_all,cron_line_numbers_to_be_deleted)
   submit_crontab(newcron)
end

local function DEFUNCTdelete_old_cron_jobs()
   local cron = get_cron_jobs()
   local cron_to_be_checked = {}
   local cron_line_numbers_to_be_deleted = {}
   local cron_line_numbers_not_to_be_deleted = {}
   local cron_text_to_be_deleted = {}
   local cron_text_not_to_be_deleted = {}

   for k,v in ipairs(cron.cronjob_dispositions) do
      if k:match("#%s*TMP%s*$") then
	 table.insert(cron_to_be_checked,k)
      end
   end
   for k,v in ipairs(cron_to_be_checked) do
      local field1, field2, field3, field4, field5 = cron.cronjob_schedules[v]:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
      if (field1 and field2 and field3 and field4) and not (field1 == "*" or field2 == "*" or field3 == "*" or field4 == "*") and field5:sub(-4,-1) == "#TMP" then
	 local field1num, field2num, field3num, field4num = tonumber(field1), tonumber(field2), tonumber(field3), tonumber(field4)
	 if field1 and field2 and field3 and field4 then
	    local now = os.time()
	    local field_time = os.date({min=field1num,hour=field2num,day=field3num,month=field4num})
	    if field_time < now then
	       table.insert(cron_line_numbers_to_be_deleted,cronjob_line_numbers[k])
	       table.insert(cron_text_to_be_deleted,v)
	    else
	       table.insert(cron_line_numbers_not_to_be_deleted,k)
	       table.insert(cron_text_not_to_be_deleted,cronjob_line_numbers[k])
	    end
	 end
      end
   end
   local newcron = tblDeleteLines(cron_all,cron_line_numbers_to_be_deleted)
--   WriteArrayAsFile(newcron,"tmpfile")
--   local newcron_cmd = [[ bash -c 'echo -e ]]..string.format("%q",table.concat(newcron,"\n"))..[[ | crontab -']]
--   os.execute(newcron_cmd)
   submit_cron(cron.cron_all)
end
   

local keywords_used_array = {}
local keywords_pos_array = {}
local date_in_question_tbl = {}
local date_range_ends_tbl = {}
local date_duration_tbl = {}

local function find_next_keywords_pos(pos)
   for _,i in ipairs(keywords_pos_array) do
      if i > pos then
	 return i
      end
   end
   return nil
end

-- useful for parsing position independent commands
local function merge_stuff_following_keyword(keyword, line, target_tbl, pattern_matching_function, starting_date_tbl)
   -- keyword = keyword:match'^%s*(.*%S)%s*' or ''
   -- keyword = " "..keyword.." "
   pos_tmp = line:find(keyword)
   if pos_tmp then
      local pos_date_begins = pos_tmp + string.len(keyword)
      local pos_date_ends = find_next_keywords_pos(pos_tmp)
      if not pos_date_ends then
	 pos_date_ends = string.len(line)
      end
      local tmp_string = line:sub(pos_date_begins,pos_date_ends)
      pp("merge_stuff following: " .. keyword)
      pp(tmp_string)
      pp(starting_date_tbl)
      local tmp_date_tbl = pattern_matching_function(tmp_string, starting_date_tbl)
      pp("tmp_date_tbl:")
      pp(tmp_date_tbl)
      if not is_empty(tmp_date_tbl) then  -- tblShallowMerge
	 for k,v in pairs(tmp_date_tbl) do
	    target_tbl[k] = v       
	 end
      end
      return target_tbl      
   else
      return nil
   end
end


local function leave_out_date_range_ends_info(line)
   local pos_of_range_end_keyword
   local pos_of_end_of_range_end
   local retval
   local end_range_keyword
   for k,v in ipairs(keywords_used_array) do
      if is_range_ends_keyword[v] then
	 end_range_keyword = v
	 pos_of_range_end_keyword = keywords_pos_array[k]
	 pos_of_end_of_range_end = find_next_keywords_pos(pos_of_range_end_keyword)
	 if not pos_of_end_of_range_end then
	    pos_of_end_of_range_end = #line
	 end
	 break
      end
   end
   if pos_of_range_end_keyword then
      pp("end_range_keyword = "..end_range_keyword)
      pp("pos_of_range_end_keyword = "..pos_of_range_end_keyword)
      pp("pos_of_end_of_range_end = "..pos_of_end_of_range_end)
      retval = line:sub(1,pos_of_range_end_keyword).." "..line:sub(pos_of_end_of_range_end,-1)
      retval = retval:gsub("%s+"," ")
   else
      retval = line
   end
   return retval
end


local function maxArrayValueAndItsKey(t, fn)
    if #t == 0 then return nil, nil end
    local key, value = 1, t[1]
    for i = 2, #t do
        if fn(value, t[i]) then
            key, value = i, t[i]
        end
    end
    return key, value
end


--- Assume that the computer was offline during the last cron
--- statement regarding device and execute it.  If there is no
--- argument passed to this function then go through the entire
--- list of devices_for_which_to_execute_last_cron_statement and do
--- them all
local function execute_last_cron_statement_regarding_device( devices_to_execute )
   local cj = get_cron_jobs()
   local devices_for_which_to_execute_last_cron_statement_on_boot = devices_for_which_to_execute_last_cron_statement_on_boot
   if devices_to_execute and type(devices_to_execute == "table") then 
      devices_for_which_to_execute_last_cron_statement_on_boot = tblShallow_copy( devices_to_execute )
   end
   for i,device in ipairs(devices_for_which_to_execute_last_cron_statement_on_boot) do
      local cron_in_the_running_list = {}
      local cron_in_the_running_list_times = {}
      local devicenum = device_in_question_to_device_number[device]
      print_current_datetime()
      pp(ins(cj))
--      pp(dispositions_cmdline[1][1])  -- 1 is off and 2 is on
      for k,v in ipairs( cj.cronjob_dispositions ) do
	 -- pp(v.." == "..dispositions_cmdline[devicenum][1].." or "..dispositions_cmdline[devicenum][2].." ?")
	 
	 if v == dispositions_cmdline[devicenum][1] or v == dispositions_cmdline[devicenum][2] then
	    table.insert(cron_in_the_running_list,k)
--	    local a = ccparse("0 "..cj.cronjob_schedules[k]) -- debug
	    pp("parsing: 0 "..cj.cronjob_schedules[k])
	    
	    pp(cj.cronjob_schedules[k])
--	    local c = ccprev(a)        -- debug: not working properly
--	    pp(v.." = "..c)
	                               -- Temporary work around:
	    local handle_c2 = io.popen('./cron_last_epoch_time_this_line_was_supposedly_executed "'..cj.cronjob_schedules[k]..'"')
	    local c2 = handle_c2:read("*a")
	    handle_c2:close()
	    table.insert(cron_in_the_running_list_times,c2)
	 end
      end
      pp("cron_in_the_running_list_times:")
      pp(ins(cron_in_the_running_list_times))
      local k,v = maxArrayValueAndItsKey(cron_in_the_running_list_times, str_is_less_than_p)
      pp("NOW starting the `on boot we must execute' directive(s):")
      pp(cj.cronjob_dispositions[cron_in_the_running_list[k]]) 
--      os.execute(cj.cronjob_dispositions[cron_in_the_running_list[k]])
   end -- for each device ends here --
end

local function tbl_to_schedule_string (tbl)
   if tbl.dow_recurring_written_out then
      tbl.day = '*'
      tbl.month = '*'
   end
   if not tbl.hour then
      tbl.hour = 0
   end
   if not tbl.min then
      tbl.min = 0
   end
   -- if not tbl.day then
   --    tbl.day = "*"
   -- end
   -- if not tbl.month then
   --    tbl.month = "*"
   -- end

   local dow = tbl.dow_recurring_written_out
   if not dow then 
      dow = "*"
   end
   schedule_string = tbl.min.." "..tbl.hour.." "..tbl.day.." "..tbl.month.." "..dow

   -- if tbl.min then 
   --    schedule_string = schedule_string.." "..tbl.min
   -- end    
   -- if tbl.hour then
   --    schedule_string = schedule_string.." "..tbl.hour
   -- end
   -- if tbl.day then
   --    schedule_string = schedule_string.."
   return schedule_string
end


local function tbl_is_now_p(tbl)
   local now = os.date('*t')
   if tbl and tbl.min == now.min and tbl.hour == now.hour and tbl.day == now.day and tbl.month == now.month then
      return true
   else
      return false
   end
end

-- The mechanism of add_new_schedule() is as follows: when a new
-- schedule is added that does not involve turning a device both on
-- and off, then it is simply added to the crontab.  If it does
-- involve turning a device both on and off then the schedule is added
-- to the crontab, along with an additional line in the crontab
-- scheduling, on that same day, for the crontab to be cleared of any
-- conflicts with the aforementioned schedule.  When that clearing
-- request eventually takes place, on the date of the new schedule,
-- then all crontab lines that involve turning on or off said device
-- that happen to occur during the new schedule will be placed on hold
-- temporarily, in addition to yet an additional crontab line that
-- schedules for the unholding of said held schedules, along with the
-- deletion of the new schedule, start to end, to take place at the
-- delimiting new schedule
local function add_new_schedule(tbl_begin, disposition_begin, tbl_end, disposition_end)


   local cj = get_cron_jobs()
   local new_schedule_begin = tbl_to_schedule_string(tbl_begin)
   local new_cronline = new_schedule_begin.." "..disposition_begin
   pp("new_cronline=="..new_cronline)
   local new_cronline_begin_md5 = md5.sumhexa(new_cronline)
   pp("new_cronline_begin_md5=="..new_cronline_begin_md5)
   new_cronline = new_cronline.." #TMP"
   if cj.cronjob_md5sumhexa[new_cronline_begin_md5] then
      new_cronline = ""
      print'cronline schedule already exists in crontab'
   else
      table.insert(cj.cron_all,new_cronline)
   end
   
   local new_cronline_end_md5
      
   
   pp("adding new cronline: "..new_cronline)
   if tbl_end then
      local new_schedule_end = tbl_to_schedule_string(tbl_end)
      new_cronline = new_schedule_end.." "..disposition_end
      new_cronline_end_md5 = md5.sumhexa(new_cronline)
      if cj.cronjob_md5sumhexa[new_cronline_end_md5] then
	 print'end schedule already exists in crontab'
      else
	 new_cronline = new_cronline.." #TMP"
	 table.insert(cj.cron_all,new_cronline)
	 table.insert(cj.cron_all,new_schedule_begin.." "..smart_device_client_program.." clear schedule for "..new_cronline_begin_md5.." "..new_cronline_end_md5)
	 pp("also adding new cronline: "..new_cronline)
	 pp("also adding yet another croline: "..new_cronline_begin_md5.." "..new_cronline_end_md5)
      end
   end

   submit_crontab(cj.cron_all)
   if tbl_is_now_p(tbl_begin) and tbl_end then  -- EXECUTE NOW
      pp("Proceeding in 0.5 seconds to clear schedule for:")
      pp(new_cronline_begin_md5)
      pp(new_cronline_end_md5)
      sleep(0.5)
      clear_schedule_for(new_cronline_begin_md5, new_cronline_end_md5) 
   end
end

local function flag_error(msg,client)
   client:send(msg)
end

local function escape_pattern(text)
   pp("escaping the following text:")
   pp(text)
   if not text then return "" end
   pp( text:gsub("([^%w])", "%%%1"))

   return text:gsub("([^%w])", "%%%1")
end

-- Say you wanna search a small html file for a particular string,
-- which happens to recur ubiquitously in the file, like for example
-- enabled or disabled.  And, there happens to be headings and
-- subheadings that you can search to get you closer to the context of
-- the string.  Well then, this is the function for you.  The file
-- must be passed as a table of lines via the first parameter.  The
-- second and third parameters are the contexts immediately preceeding
-- and following, respectively, the target string you are interested
-- in, on the same line.  All the remaining varied number of
-- parameters are to be strings to search in succession, one per line,
-- to get you closer to that target line context.
local function tblContext_line_succession_search( tblText, strFore_delimiter, strEnd_delimiter,...)
   local function escape_pattern(text)
      pp("escaping the following text:")
      pp(text)
      if not text then return "" end
      pp( text:gsub("([^%w])", "%%%1"))
      
      return text:gsub("([^%w])", "%%%1")
   end
   local number_of_searches = select('#',...)
   local found_linenum
   local search_num = 0
   local found_line_text
   local escaped_search_pattern = escape_pattern(select(search_num + 1,...))
   for k,v in ipairs(tblText) do
      if v:match(escape_search_pattern) and search_num < number_of_searches  then
	 found_linenum = k
	 found_line_text = v
	 search_num = search_num + 1
	 if search_num == number_of_searches then break end
	 escaped_search_pattern = escape_pattern(select(search_num + 1,...))
      end
   end
   
   if search_num == number_of_searches then
      local pattern = escape_pattern(strFore_delimiter).."(.*)"..escape_pattern(strEnd_delimiter)
      return found_line_text:match(pattern)
   else
      return nil
   end
end


-- This function is a modified tblContext_line_succession_search()
local function tblContext_line_succession_search_device_status( tblText, device)
   local number_of_searches = #device_status_query_texts[device] -2 
   local found_linenum
   local search_num = 0
   local found_line_text
   local strFore_delimiter = device_status_query_texts[device][2]
   local strEnd_delimiter = device_status_query_texts[device][3]
   local escaped_search_pattern = escape_pattern(device_status_query_texts[device][search_num+3])
   for k,v in ipairs(tblText) do
      if v:match(escaped_search_pattern) and search_num < number_of_searches  then
	 found_linenum = k
	 found_line_text = v
	 search_num = search_num + 1
	 if search_num == number_of_searches then break end
	 
	 escaped_search_pattern = escape_pattern(device_status_query_texts[device][search_num+3])
      end
   end
   
   if search_num == number_of_searches then
      local pattern = escape_pattern(strFore_delimiter).."(.*)"..escape_pattern(strEnd_delimiter)
      return found_line_text:match(pattern)
   else
      return nil
   end
end



local function device_status( device )
--   f = io.open("curled_router.html", "r")
   local f = io.popen("curl "..device_ip_addresses[device]..device_status_query_texts[device][1])
   pp("curl "..device_ip_addresses[device]..device_status_query_texts[device][1])

   local line
   local tblFiletext ={}
   for line in f:lines() do
      table.insert(tblFiletext,line)
      pp(line)
   end
   
   return tblContext_line_succession_search_device_status(tblFiletext, device)
end

   
--    local tmphandle = io.popen("crontab -l 2>" .. errormsg_file)
-- --debug   local tmphandle = io.popen("cat crontable") --debug
--    local result = tmphandle:read("*a")
--    if not result then
--       return nil
--    end	   
--    tmphandle:close()
   
			   


----------------- end of function declarations --------------

execute_last_cron_statement_regarding_device()
local server = assert(socket.bind("*", port_number_for_which_to_listen))
local ip, port = server:getsockname()
local client


while 1 do
   local two_part_cmd = false
   date_in_question_tbl = {}
   date_duration_tbl = {}
   date_range_ends_tbl = {}
   keywords_used_array = {}
   keywords_pos_array = {}
   local cjs = get_cron_jobs()
   client = server:accept()
   client:settimeout(30)
   local line, err = client:receive()
   prepositions_pos_index = {}
   line = line:gsub("\t"," ")
   line = line:match'^%s*(.*%S)' or ''
   pp("line #####:")
   pp(line)

   if not err then
      pp("################################################################################")
      if line:sub(1,4) == "list" then
	 local tmphandle = io.popen("crontab -l 2>" .. errormsg_file)
	 local result = tmphandle:read("*a")
	 tmphandle:close()
	 print'requested: list'
	 print_current_datetime()
	 if not result then
	    client:send("no results\n")	   
	    --tmphandle = io.open(errormsg_file, "rb")
	    --result = tmphandle.lines
	    for result in io.lines(errormsg_file) do 
	       client:send(result .. "\n")	   
	    end
	 else	   
	    client:send(result .. "\n")
	    cjs = get_cron_jobs()
	    pp(ins(cjs))
	 end
      -- elseif line == "turn on wifi" or line == "turn wifi on" or line == "enable wifi" then
      -- 	 --	os.execute(dispositions_cmdline["wifi"]["on"])
      -- 	 pp("enable wifi")
      elseif starts_with(line,"md5") then
	 local tmphandle = io.popen("crontab -l 2>" .. errormsg_file)
	 local result = tmphandle:read("*a")
	 tmphandle:close()
	 print'requested: md5'
	 print_current_datetime()
	 if not result then
	    client:send("no results\n")	   
	    --tmphandle = io.open(errormsg_file, "rb")
	    --result = tmphandle.lines
	    for result in io.lines(errormsg_file) do 
	       client:send(result .. "\n")	   
	    end
	 else	   
	    client:send(result .. "\n")
	    cjs = get_cron_jobs()
	    client:send("---------- md5sum of each uncommented line: ------------------------\n")
	    for k,v in ipairs(cjs.cronjob_md5sumhexa) do
	       if (cjs.cronjob_md5sumhexa_to_cronline[v]) then
		  client:send(cjs.cronjob_md5sumhexa_to_cronline[v] .. "\n")
	       end
	       if v then
		  client:send(v .. "\n")
	       end
	    end
	    client:send("---------- md5sum of held line item: ------------------------\n")
	    local onholdjobs_list_size = #cjs.onholdjobs  
	    for k,v in ipairs(cjs.onholdjobs) do
	       client:send(v .. "\n")
	       client:send(cjs.onholdjob_md5sumhexa[k] .. "\n")
	       client:send("line number: "..cjs.onholdjob_line_numbers[k] .. "\n")
	       
	    end
	    pp(ins(cjs))
	 end
      elseif starts_with(line,"delete old") then
	 delete_old_cron_jobs()
      elseif starts_with(line,"test") then
	 pp("testing: hello there")
	 client:send("hello there")
      elseif starts_with(line,"status") then
	 local device = line:match("status (.*)%s?")
	 
	 print'requested: status'
	 print_current_datetime()
	 local strStatus = device_status(device)
	 if strStatus and device then
	    client:send("status of "..device.."="..strStatus.."\n")	 
	 end
      elseif starts_with(line,"temp") or starts_with(line,"tmp") then
	 
	 -- temperature of tinker board s, but will also work for raspberry pi
	 local tmphandle = io.popen("cat /sys/devices/virtual/thermal/thermal_zone0/type;cat /sys/devices/virtual/thermal/thermal_zone0/temp;cat /sys/devices/virtual/thermal/thermal_zone1/type;cat /sys/devices/virtual/thermal/thermal_zone1/temp;cat /sys/devices/virtual/thermal/cooling_device0/type;cat /sys/devices/virtual/thermal/cooling_device0/cur_state;cat /sys/devices/virtual/thermal/cooling_device1/type;cat /sys/devices/virtual/thermal/cooling_device1/cur_state\n")
	 local result = tmphandle:read("*a")
	 tmphandle:close()
	 print'requested: temp'
	 print_current_datetime()
	 if result then

	    client:send(result .. "\n")
	 end
      elseif starts_with(line,"ver") then
	 pp("smart_device_svr.lua version="..version)
	 client:send("smart_device_svr.lua version="..version.."\n")	 
      elseif starts_with(line, "unhold all") then
	 unhold_all_jobs()
      elseif starts_with(line, "hold all") then
	 hold_all_jobs()
      elseif starts_with(line, "clear") then  -- clear schedule for

	 print'requested: clear'
	 print_current_datetime()
	 local md5sum_begin, md5sum_end = line:match("^clear schedule for %s*(%x+)%s*[, ]?%s*(%x+)%s*$")
	 if md5sum_begin and md5sum_end then
	    clear_schedule_for(md5sum_begin,md5sum_end)
	 end
      elseif starts_with(line, "unhold") or starts_with(line, "delete") then
	 print'requested: unhold'
	 print_current_datetime()
	 local unhold_str = line:match("unhold (.*) delete")
	 if not unhold_str then
	    unhold_str = line:match("unhold (.*)$")
	 end
	 local delete_str = line:match("delete (.*) unhold")
	 if not delete_str then
	    delete_str = line:match("delete (.*)$")
	 end	    
	 unhold_jobs_delete_jobs(unhold_str, delete_str)
      elseif starts_with(line, "0") then
	 pp("os.execute("..dispositions_cmdline[1][1]..")")
	 os.execute(dispositions_cmdline[1][1])
      elseif starts_with(line, "1") then
	 pp("os.execute("..dispositions_cmdline[1][2]..")")
	 os.execute(dispositions_cmdline[1][2])
      else     ---- variant commands start here ----------------------------------------------------------------------------------
	 local original_predicate, pos_original_predicate, pos_original_predicate_ends
	 local no_device_was_specified = false
	 local action, device_in_question, device_number, disposition_state, disposition_state_num, temp_value_holder
	 local month,day,year,hour,min,second,week,weekstart_day,day_of_the_year, military_time,dow_week
	 local is_disposition_state
	 local acknowledge = line 
	 for _,v in ipairs(default_actions_list) do
	    acknowledge = acknowledge:gsub(v,v.."ing")
	 end
	 acknowledge = acknowledge.."\n"
	 client:send(acknowledge)
	 for word in line:gmatch("%w+") do  -- first find device
	    if is_device[word] == true then
	       device_in_question = word
	       device_number = device_in_question_to_device_number[word]
	       break
	    end
	 end
	 if not device_in_question then  -- no device was specified so assume first device, now find action and disposition state number
	    no_device_was_specified = true
	    device_in_question = devices_list[1]
	    device_number = 1
	    for word in line:gmatch("%w+") do
	       if is_action[word] then
		  action = word
		  pos_original_predicate = line:find(action)
		  local disposition_states_to_disposition_state_numbers = make_reverse_lookup_table(disposition_states[device_number])
		  local possible_disposition_state = line:match(action.."%s*(%w+)")
		  disposition_state_num = disposition_states_to_disposition_state_numbers[possible_disposition_state]
		  is_disposition_state = Set(disposition_states[device_number])
		  break
	       end
	    end
	    	    
	 else  -- device_in_question was specified, now find action

 
	    local disposition_states_to_disposition_state_numbers = make_reverse_lookup_table(disposition_states[device_number])
	    local possible_pos_original_predicate, possible_pos_original_predicate_ends, possible_disposition_state1, possible_disposition_state2 = line:find("(%w+)%s+"..device_in_question.."%s*(%w*)")
	    is_disposition_state = Set(disposition_states[device_number])
	    if is_action[possible_disposition_state1] then
	       action = possible_disposition_state1
	       pos_original_predicate = possible_pos_original_predicate
	       if is_disposition_state[possible_disposition_state2] then
		  disposition_state = possible_disposition_state2
		  disposition_state_num = disposition_states_to_disposition_state_numbers[disposition_state]
		  pos_original_predicate_ends = possible_pos_original_predicate_ends
		  
	       else -- possible_disposition_state2 is not a disposition state
		  local _
		  _,pos_original_predicate_ends = line:find(device_in_question)
		  disposition_state = possible_disposition_state1
		  disposition_state_num = disposition_states_to_disposition_state_numbers[disposition_state]

	       end
	    elseif is_disposition_state[possible_disposition_state1] then 
	       disposition_state = possible_disposition_state1
	       disposition_state_num = disposition_states_to_disposition_state_numbers[disposition_state]
	       local possible_pos_original_predicate, possible_pos_original_predicate_ends, possible_action = line:find("(%w+)%s+"..disposition_state.."%s+"..device_in_question)
	       if is_action[possible_action] then
		  action = possible_action
		  pos_original_predicate = possible_pos_original_predicate
		  pos_original_predicate_ends = possible_pos_original_predicate_ends
	       end
	    end
	    
	 end  -- no device specified condition ends here --
	 if not action then
	    flag_error("error: an action must be specified, such as turn on, turn off, enable, or disable.\n",client)
	 else
	    
	    pp("action = "..action)
	    pp("disposition_state = "..disposition_state)
	    local disposition_states_to_disposition_state_numbers = make_reverse_lookup_table(disposition_states[device_number])
	    disposition_state_num = disposition_states_to_disposition_state_numbers[disposition_state]
	    pp("disposition_state_num = "..disposition_state_num)
	    pp("disposition = "..dispositions_cmdline[device_number][disposition_state_num]);
	
	    pp("pos_original_predicate = "..pos_original_predicate)
	    pp("pos_original_predicate_ends= "..pos_original_predicate_ends)
	    pp("line: "..line)
	    pp("removing from line: "..line:sub(pos_original_predicate,pos_original_predicate_ends))
	    if pos_original_predicate == 1 then
	       line = line:sub(pos_original_predicate_ends+1,-1)
	    elseif pos_original_predicate_ends == #line then
	       line = line:sub(1,pos_original_predicate-1)
	    else
	       line = line:sub(1,pos_original_predicate-1)..line:sub(pos_original_predicate_ends+1,-1)
	    end
		    
	    line = line:gsub("%s+"," ")  -- remove_extra_spaces(line)
	    line = trim(line)
	    line = " "..line.." "
	    
	    local new_line,dow_recurring_string, prepend_to_cron_diposition = extract_dow_recurring(line)
	    if new_line and new_line ~= "" then
	       line = new_line
	       date_in_question_tbl.dow_recurring_written_out = dow_recurring_string
	       pp'new_line:'
	       pp(new_line)
	       pp'dow_recurring_string'
	       pp(dow_recurring_string)
	    end
	    line = replace_for_the_next_clause(line)
	    line = line:gsub("/","-")
	    
	    pp("line after removal: "..line)
	    local possible_disposition_state_num = actions_to_disposition_number[action]	
	    if possible_disposition_state_num ~= 0 then   -- disable or enable
	       disposition_state_num = possible_disposition_state_num
	    end
	    

	    pp(action,disposition,device_in_question, pos_original_predicate)     
	    
	    line = line:gsub("%s+"," ")  -- remove_extra_spaces(line)
	    line = trim(line)
	    line = " " .. line .. " "           
	 
	    pp(line)	 
	    for _,v in ipairs(keywords_array) do  -- populate keywords pos
	       tmp_val = line:find(v)
	       if tmp_val then
		  table.insert(keywords_used_array,v)
		  table.insert(keywords_pos_array,tmp_val)
	       end
	    end
	    table.insert(keywords_used_array,device_in_question)
	    table.insert(keywords_pos_array,pos_original_predicate - 1)	
	    bubbleSortAssociatedArrays(keywords_pos_array,keywords_used_array)
	    -- find duration phrase that effects date in question
	    -- find date_range_phrase
	    -- find date_in_question_phrase	    
	    
	    local tmp_tbl = {}
	    for _, keyword in ipairs(date_in_question_keywords) do
	       --	    date_in_question_tbl = merge_stuff_following_keyword(keyword, line, date_in_question_tbl, variant_date_parser) or date_in_question_tbl
	       merge_stuff_following_keyword(keyword, line, date_in_question_tbl, variant_date_parser)
	       pp("date_in_question_tbl")
	       pp(ins(date_in_question_tbl))
	    end
	    pp("date_in_question_tbl")
	    pp(ins(date_in_question_tbl))
	    
	    if not (date_in_question_tbl.day and date_in_question_tbl.month ) then
	       pp("not date_in_question_tbl.day month and day in original line")
	       local dow_in_question = date_in_question_tbl.dow_written_out
	       if dow_in_question then
		  tmp_tbl = date_of_next_dow(dow_in_question)
		  for k,v in pairs(date_in_question_tbl) do
		     tmp_tbl[k] = v
		  end
		  date_in_question_tbl  = tmp_tbl
	       elseif merge_stuff_following_keyword(date_in_question_by_duration_keywords[1], line, tmp_tbl, in_future_time_parser, os.date("*t")) then
		  pp'has in_future_time_parser info:'
		  pp(ins(tmp_tbl))
		  tblShallow_fill_in_missing(date_in_question_tbl,tmp_tbl)
	       else -- if all else fails in finding a date in question, then try to parse the line, minus any date_end_range parts, as the date_in_question
		  pp("if all else fails try to parse the line, minus any date_end_range parts, as the date_in_question")
		  local line_without_end_range_info = leave_out_date_range_ends_info(line)	       
		  date_in_question_tbl = variant_date_parser(line_without_end_range_info) or date_in_question_tbl  
		  if not (date_in_question_tbl.day and date_in_question_tbl.month ) then
		     local dow_written_out  = find_dow(line_without_end_range_info)
		     if dow_written_out then
			pp'dow_written_out'
			tmp_tbl = date_of_next_dow(dow_written_out)
			for k,v in pairs(date_in_question_tbl) do
			   tmp_tbl[k] = v
			end
			date_in_question_tbl  = tmp_tbl
		     -- elseif date_in_question_tbl.dow_recurring_written_out then
			elseif dow_recurring_string then
			   -- this is not being called for some reason, so its also been placed in tbl_to_schedule_string() 
			pp'date_in_question_tbl.dow_recurring_written_out'
			pp(date_in_question_tbl.dow_recurring_written_out)
			date_in_question_tbl.month = '*'
			date_in_question_tbl.day = '*'
		     else 
			-- assume today is the date in question, unless there is an 'in' keyword
			pp("date assumed to be today")
			local now_tbl = os.date("*t")
			local now_tbl_day = {}
			now_tbl_day.month = now_tbl.month
			now_tbl_day.day = now_tbl.day
			now_tbl_day.year = now_tbl.year
			tblShallow_fill_in_missing(now_tbl_day,date_in_question_tbl)
			date_in_question_tbl = now_tbl_day
			if not date_in_question_tbl.min and not date_in_question_tbl.hour then
			   date_in_question_tbl.min = now_tbl.min
			   date_in_question_tbl.hour = now_tbl.hour
			end
		     end
		  end	    
	       end   -- dow written out condition ends here --
	    end  -- doesnt contain day month condition ends here --
	    date_in_question_tbl.dow_recurring_written_out = dow_recurring_string
	    pp("date_in_question_tbl")
	    pp(date_in_question_tbl)
	    do
	       local now_is = os.date("*t")	       
	       if date_in_question_tbl.min == now_is.min and date_in_question_tbl.hour == now_is.hour and date_in_question_tbl.day == now_is.day and date_in_question_tbl.month == now_is.month then  -- EXECUTE NOW
		  pp("now invoking: turning wifi "..disposition_state_num)
		  pp("os.execute("..dispositions_cmdline[device_number][disposition_state_num]..")")
--debug	  os.execute(dispositions_cmdline[device_number][disposition_state_num])
	       end
	    end
	    
	    for _, keyword in ipairs(date_range_ends_keywords) do
	       merge_stuff_following_keyword(keyword, line, date_range_ends_tbl, variant_date_parser)
	    end
	    pp("date in question table:")
	    pp(date_in_question_tbl)
	    pp("date_range_ends_tbl")
	    pp(date_range_ends_tbl)
	    
	    --	local date_in_question_in_seconds = os.time(date_in_question_tbl)
	    --	 pp(date_in_question_in_seconds)
	    if is_empty(date_range_ends_tbl) then  -- look for duration
	       pp("date_range_ends_tbl was empty")
	       date_range_ends_tbl = tblShallow_copy(date_in_question_tbl)
	       pp("date in question table:")
	       pp(date_in_question_tbl)

	       for _, keyword in ipairs(duration_keywords) do
		  two_part_cmd = true
		  date_range_ends_tbl = merge_stuff_following_keyword(keyword, line, date_range_ends_tbl, in_future_time_parser, date_in_question_tbl) or nil  -- this stmt only works for 1 keyword, in this case 'for', and needs to be revised
		  
		  if not date_range_ends_tbl or tblShallow_is_equal(date_in_question_tbl, date_range_ends_tbl) then
		     two_part_cmd = false
		  else
		     two_part_cmd = true
		     date_range_ends_tbl.dow_recurring_written_out = date_in_question_tbl.dow_recurring_written_out
		     pp("date_range_ends_tbl")
		     pp(date_range_ends_tbl)
		     
		  end
	       end
	    else         -- try to figure out end range date first by seeing if there is a dow
	       two_part_cmd = true
	       
	       date_range_ends_tbl.dow_recurring_written_out = date_in_question_tbl.dow_recurring_written_out
	       
	       if dow_range_ends then
		  if date_in_question_tbl.wday and dow_range_ends < date_in_question_tbl.wday then
		     dow_week = 2
		  else
		     dow_week = 1
		  end
		  tmp_tbl = date_of_next_dow(dow_range_ends, dow_week)
		  for k,v in pairs(date_range_ends_tbl) do
		     tmp_tbl[k] = v
		  end
		  date_range_ends_tbl  = tmp_tbl
	       elseif not (date_range_ends_tbl.day and date_range_ends_tbl.month ) then  -- assume end date maybe lies on same month and day as date in question
		  tblShallow_fill_in_missing(date_range_ends_tbl, date_in_question_tbl)
		  
	       end
	       pp("final date_range_ends:")
	       pp(ins(date_range_ends_tbl))
	    end  -- is empty date_range_ends_tbl condition ends here --
	    pp("disposition_state_num")
	    pp(disposition_state_num)
	    local end_disposition_state_num = 2 - (disposition_state_num + 1 ) % 2
	    add_new_schedule(date_in_question_tbl,dispositions_cmdline[device_number][disposition_state_num], date_range_ends_tbl, dispositions_cmdline[device_number][end_disposition_state_num])
	 end -- else not action ends here --
      end  -- else variant command ends here --
   end  -- else not err ends here --
   pp(ins(keywords_used_array))
   pp(ins(keywords_pos_array))  
   client:close()
end -- while ends here --



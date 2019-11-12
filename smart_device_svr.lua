#!/usr/local/bin/luajit
--[[

     This server script schedules the switching on or off of smart
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


     Compiling notes:
          Compiling can be accomplished by the command make all, executed from the root directory of the unzipped archive.

          ccronexpr.so is compiled using the following statement:
             gcc -o ccronexpr.so ccronexpr.c -shared -fPIC -DCRON_USE_LOCAL_TIME
          
          luajit and luasocket must be compiled, in their respective directories, with:
             make && make install 

     Scheduling:
          # This is an example crontab I've been using ( set with crontab -e, notice that there are no seconds fields ):


            59 21 * * sun,mon,tue,wed,thu screen -dm emacs -nw -Q -l /home/pi/scripts/disable_wifi.el

            0 15 * * mon,tue,wed,thu,fri screen -dm emacs -nw -Q -l /home/pi/scripts/enable_wifi.el
            59 23 * * fri,sat screen -dm emacs -nw -Q -l /home/pi/scripts/disable_wifi.el
            0 7 * * sat,sun screen -dm emacs -nw -Q -l /home/pi/scripts/enable_wifi.el

   
     References:  
          ccronexpr.c is from https://github.com/staticlibs/ccronexpr

          The lua wrapper to ccronexpr.c is from
          https://github.com/tarantool/cron-parser/blob/master/cron-parser.lua

          table.save-1.0.lua is from http://lua-users.org/wiki/SaveTableToFile

          md5.lua is from https://github.com/kikito/md5.lua/blob/master/md5.lua

          LuaJIT-2.0.5 is from http://luajit.org/download.html

     Authors/Maintainers: ciscorx@gmail.com
       Version: 0.0
       Commit date: 2019-10-26

       7z-revisions.el_rev=0.0
       7z-revisions.el_sha1-of-last-revision=b628fbc14d65851699cf40874badfb2f6cb953ec
--]]

local devices_list = {"wifi"}
local dispositions_cmdline = {{"screen -dm emacs -nw -Q -l disable_wifi.el","screen -dm emacs -nw -Q -l enable_wifi.el"}}
local disposition_states = {{"off","on"}}
local devices_for_which_to_execute_last_cron_statement_on_boot = {"wifi"}

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
]]


local cron = ffi.load("./ccronexpr.so")
local errormsg_file = "/tmp/.errormsg.txt"
local smart_device_client_cmd = "send_to_smart_device_svr.lua"
local port_number_for_which_to_listen = 29998
local onhold_token = "^#%s*ON%s*HOLD%s*(%x*)%s*(%x*)#%s*"
local tmp_token = " #TMP"  -- this token must include a preceding space
local default_actions_list = {"turn","disable","enable"}
local default_action_disposition_numbers = {0,1,2}

local months = {jan=1,feb=2,mar=3,apr=4,may=5,jun=6,jul=7,aug=8,sep=9,oct=10,nov=11,dec=12}
local dow = {su=0,mo=1,tu=2,we=3,th=4,fr=5,sa=6}
local dow_recurring = {sundays=0,mondays=1,tuesdays=2,wednesdays=3,thursdays=4,fridays=5,saturdays=6}
local dow_recurring_abbrv = {sun=0,mon=1,tue=2,wed=3,thu=4,fri=5,sat=6}
local time_zoneinfo = { z=0,ut=0,gmt=0,pst=-8*3600,pdt=-7*3600
			,mst=-7*3600,mdt=-6*3600
			,cst=-6*3600,cdt=-5*3600
			,est=-5*3600,edt=-4*3600}


local function make_reverse_lookup_table(tbl)
   local reverse_lookup_table = {}
   for k,v in pairs(tbl) do
      reverse_lookup_table[v] = k
   end
   return reverse_lookup_table
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
local date_in_question_keywords = { 'on', 'for', 'at', 'from', 'starting', 'beginning' }
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
-- add_space_to_beginning_and_ending_of_each_list_item(keywords_array)
-- add_space_to_beginning_and_ending_of_each_list_item(date_in_question_keywords)
-- add_space_to_beginning_and_ending_of_each_list_item(date_in_question_by_duration_keywords)
-- add_space_to_beginning_and_ending_of_each_list_item(duration_keywords)
-- add_space_to_beginning_and_ending_of_each_list_item(date_range_ends_keywords)
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

local function extract_dow_recurring(str)
   local possible_pos, possible_endpos,possible_dow,firstpos, lastpos
   local dows_found = false
   local startingpos = 1
   local retval_tbl = {}
   local retval_num_tbl = {}
   local retval = ""
   local i = 0


   repeat
      possible_pos,possible_endpos,possible_dow = string.find(str," ([mtwtfss][ouehrau])", startingpos)
      pp(possible_dow)	 
      if possible_dow then
	 possible_pos,possible_endpos,possible_dow = string.find(str, "(%l+)", possible_pos)
	 pp(possible_pos)
	 pp(possible_endpos)
	 pp(possible_dow)
	 startingpos = possible_endpos
	 if dow_recurring[possible_dow] then
	    i = i + 1
	    if i == 1 then
	       firstpos = possible_pos
	    end
	    lastpos = possible_endpos	    
	    table.insert(retval_tbl, dow_recurring[possible_dow])
--	    table.insert(retval_num_tbl, dow_recurring[possible_dow])
	 end      
      else
	 dows_found = true
      end
   until dows_found == true
   pp(retval_tbl)
   if #retval_tbl > 0 then
      table.sort(retval_tbl)
      for _,k in ipairs(retval_tbl) do
	 retval = retval .. "," .. dow_recurring_abbrv_reverse_lookup[k]
      end
      retval = retval:gsub("^,","")
      local through_pos = str:find(" through ",firstpos)
      local spanning_dow = false
      if not through_pos or through_pos > lastpos then
	 local dash_pos = str:find("-", firstpos)
	 if dash_pos and dash_pos < lastpos then
	    spanning_dow = true
	 end
      else
	 spanning_dow = true
      end
      if spanning_dow == true then
	 retval = ""
	 for i = retval_tbl[1],retval_tbl[#retval_tbl] do
	    retval = retval .. "," .. dow_recurring_abbrv_reverse_lookup[i]
	 end
	 retval = retval:gsub("^,","")
      end
      return str:sub(1,firstpos-1).." "..str:sub(lastpos+1),retval
   else  -- repeat the above for abbreviated days of the week separated by commas, there must exist at least 1 comma for this to work
      startingpos = 1
      i = 0

      dows_found = false
      local acceptable_startpos
      local possible_endpos
      local first_iteration_of_loop = true
      repeat
	 possible_pos,possible_endpos, possible_dow = string.find(str,"[, ]([mtwtfss][ouehrau][neduitn])[, ]", startingpos)
	 if possible_dow then
	    pp(possible_dow)
	    startingpos = possible_endpos
	    if first_iteration_of_loop then
	       first_iteration_of_loop = false
	       if dow_recurring_abbrv[possible_dow] then
		  table.insert(retval_tbl, dow_recurring_abbrv[possible_dow])
--		  table.insert(retval_num_tbl, dow_recurring[possible_dow])
		  acceptable_startpos = possible_endpos
		  i = i + 1
		  if i == 1 then
		     firstpos = possible_pos
		     local every_pos = str:find("every%s+"..possible_dow)
		     if every_pos then 
			firstpos = every_pos
		     end
		  end
		  lastpos = possible_endpos
	       else
		  dows_found = true
	       end
	    else   -- not first loop iteration --
	       if dow_recurring_abbrv[possible_dow] and (possible_pos == acceptable_startpos or possible_pos == acceptable_startpos + 1 ) then
		  table.insert(retval_tbl, dow_recurring_abbrv[possible_dow])
		  acceptable_startpos = possible_endpos
		  i = i + 1
		  if i == 1 then
		     firstpos = possible_pos
		     local every_pos = str:find("every%s+"..possible_dow)
		     if every_pos then 
			firstpos = every_pos
		     end
		  end
		  lastpos = possible_endpos		  
	       else
		  dows_found = true
	       end
	    end
	 else
	    dows_found = true
	 end
      until dows_found == true
      if #retval_tbl >= 1 then
	 for _,k in ipairs(retval_tbl) do
	    retval = retval .. "," .. dow_recurring_abbrv_reverse_lookup[k]
	 end
	 retval = retval:gsub("^,","")
	 return str:sub(1,firstpos-1).." "..str:sub(lastpos+1),retval

      else
	 return nil
      end
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
   return s:match'^%s*(.*%S)' or ''
end

local function remove_extra_spaces(s)
   return s:gsub("%s+"," ")
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
end

local function parse(raw_expr)
    -- This function acts as a wrapper to ccronexpr.c, taken from
    -- https://github.com/tarantool/cron-parser/blob/master/cron-parser.lua
    local parsed_expr = ffi.new("cron_expr[1]")
    local err = ffi.new("const char*[1]")
    cron.cron_parse_expr(raw_expr, parsed_expr, err)
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

local function next(lua_parsed_expr)
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
    local ts = cron.cron_next(parsed_expr, os.time())
    return tonumber(ts)
end

local function prev(lua_parsed_expr)
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
    local ts = cron.cron_prev(parsed_expr, os.time())
    return tonumber(ts)
end


local function in_future_time_parser(str, starting_tbl)
   pp("in_future_time_parser(" .. str ..",)")
   str = str:gsub("%s+"," ")  -- remove_extra_spaces(str)
--   str = trim5(str)
   str = str:lower()
   str = " " .. str .. " "
   local starting
   if not is_empty(starting_tbl) then
      starting = os.time(starting_tbl)
   else	    
      starting = os.time()
   end 
   local weeks = str:match(" (%d%d?%d?) ?we?e?ks? ")
   if weeks then weeks = tonumber(weeks) else weeks = 0 end
   local days = str:match(" (%d%d?%d?) ?d?a?y?s? ")
   if days then days = tonumber(days) else days = 0 end
   local mins = str:match(" (%d%d?%d?) ?mi?n?u?t?e?s? ")
   if mins then mins = tonumber(mins) else mins = 0 end
   local hours = str:match(" (%d%d?%d?%.?%d?%d?) ?ho?u?r?s? ")
   if hours then hours = tonumber(hours) else hours = 0 end
   return os.date("*t", weeks * 604800 + days * 86400 + hours * 3600 + mins * 60 + starting )
end


-- This function returns the date table of a datetime string, str.
-- str should be something resembling an RFC2822 string, such as "Fri,
-- 25 Mar 2016 16:24:56 +0100", or an iso8601 string, such as
-- "2019-12-30T23:11:10+0800, but various formats are accepted except
-- the forms DD-MM-YYYY and YYYY-DD-MM.  Also, hyphens and forward
-- slashes are interchangeable.
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
   local cron = {}
   cron.cron_all = {}
   cron.cronjobs = {}
   cron.cronjob_md5sumhexa = {}
   cron.cronjob_md5sumhexa_to_linenum = {}
   cron.cronjob_md5sumhexa_to_jobnum = {}
   cron.cronjob_schedules = {}
   cron.cronjob_dispositions = {}
   cron.cronjob_line_numbers = {}
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
   local line_num = 1
   for v in result:gmatch("[^\r\n]+") do
      table.insert( cron.cron_all,v)
      v = v:match('^%s*(.*%S)') or ''     
      
      if not v:match("^#") and v ~= '' then

	 field1, field2, field3, field4, field5, field6 = v:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
	 -- note: field 1 is actually minutes, not seconds, so we must add a seconds field so ccronexpr.c doesnt crash
	 if field6 then  
	    table.insert( cron.cronjobs,v)

	    table.insert( cron.cronjob_line_numbers, line_num)
	    table.insert( cron.cronjob_schedules, "0 "..field1.." "..field2.." "..field3.." "..field4.." "..field5)
	    if field6:sub(-#tmp_token,-1) == tmp_token then
	       table.insert( cron.cronjob_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert( cron.cronjob_md5sumhexa, md5.sumhexa(v:sub(1,-#tmp_token-1)))
	       table.insert(cron.tmp_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert(cron.tmp_schedules, "0 "..field1.." "..field2.." "..field3.." "..field4.." "..field5)
	       table.insert(cron.tmp_line_numbers, line_num)

	    else
	       table.insert( cron.cronjob_dispositions, field6)
	       table.insert( cron.cronjob_md5sumhexa, md5.sumhexa(v))
	    end
	 end
      else
	 onhold_key, onhold_key2, field1, field2, field3, field4, field5, field6 = v:match(onhold_token.."%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
	 -- note: field 1 is actually minutes, not seconds, so we must add a seconds field so ccronexpr.c doesnt crash
	 if field6 then
	    local onhold_token_begin, onhold_token_end = v:find(onhold_token)
	    
	    table.insert( cron.onholdjobs,v)
	    cron.onholdjob_key[onhold_key]=#cron.onholdjobs
	    table.insert( cron.onholdjob_line_numbers, line_num)
	    table.insert( cron.onholdjob_schedules, "0 "..field1.." "..field2.." "..field3.." "..field4.." "..field5)
	    if field6:sub(-#tmp_token,-1) == tmp_token then  -- #ON HOLD#  and #TMP
	       local md5sum = md5.sumhexa(v:sub(onhold_token_end+1,-#tmp_token-1))
	       table.insert( cron.onholdjob_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert( cron.onholdjob_md5sumhexa, md5sum )
	       table.insert( cron.cronjob_md5sumhexa, md5sum )

	       table.insert(cron.tmp_dispositions, field6:sub(1,-#tmp_token-1))
	       table.insert(cron.tmp_schedules, "0 "..field1.." "..field2.." "..field3.." "..field4.." "..field5)
	       table.insert( cron.tmp_md5sumhexa, md5sum )
	       table.insert(cron.tmp_line_numbers, line_num)
	       
	    else                   -- just #ON HOLD#
	       local md5sum = md5.sumhexa(v:sub(onhold_token_end+1,-1))
	       table.insert( cron.onholdjob_dispositions, field6)
	       table.insert( cron.onholdjob_md5sumhexa, md5sum )
	       table.insert( cron.cronjob_md5sumhexa, md5sum)

	    end
	 end
	 
      end
      line_num = line_num + 1
   end
   for k,v in ipairs(cron.cronjob_md5sumhexa) do
      cron.cronjob_md5sumhexa_to_linenum[v] = cron.cronjob_line_numbers[k]
   end
   cron.cronjob_md5sumhexa_to_jobnum = make_reverse_lookup_table(cron.cronjob_md5sumhexa)
   cron.onholdjob_md5sumhexa_reverselookup = make_reverse_lookup_table(cron.onholdjob_md5sumhexa)
   return cron
end


local function tblDeleteLines(t,d)
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

-- local function WriteArrayAsFile(t, filename)
--    local fileh = assert(io.open(filename,"w"))
--    for _, l in ipairs(t) do
--       fileh.write(l, '\n')
--    end
--    fileh:close()
-- end

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
      pp("now writing crontab")
      pp(array) --debug
      local tmpfilename = randomString(10)
local fileh = io.open("/tmp/"..tmpfilename,"w")
--debug            local fileh = io.open("/tmp/crontable","w") --debug
      for _,v in ipairs(array) do
	 fileh:write(v)
	 fileh:write("\n")
      end
      fileh:close()
      os.execute("cat /tmp/"..tmpfilename.." | crontab -")
      os.remove("/tmp/"..tmpfilename)
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

local function hold_job (cj, jobnum, md5sums_of_hold_instigator )
   if not md5sums_of_hold_instigator then
      md5sums_of_hold_instigator = ""
   end
   local cronlinenum = cj.cronjob_line_numbers[jobnum]
   local cronline = cj.cron_all[cronlinenum]
   cronline = "#ONHOLD "..md5sums_of_hold_instigator.." #"..cronline
   cj.cron_all[onholdjob_linenum] = cronline
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

-- todo: look at onholdjobs also, because they might be unheld during the
-- given time frame, specifically look at any unhold dispositions
local function clear_schedule_for(md5sums_begin,md5sum_end)
--   local md5sum_begin, md5sum_end = md5sums_string:match("(%x+)%s*[, ]?%s*(%x+)")
   local cj = get_cron_jobs()
   local job_linenumbers_to_be_held = {}
   local jobnum = cj.cronjob_md5sumhexa_to_jobnum[md5sum_begin]
   local disposition_begin = cj.cronjob_dispositions[jobnum]
   local disposition_action_begin = dispositions_to_action[disposition_begin]
   local device_begin = dispositions_to_device[disposition_begin]

   local parsed_schedule_begin = parse(cj.cronjob_schedules[jobnum])
   local jobnum = cj.cronjob_md5sumhexa_to_jobnum[md5sum_end]
   local disposition_end = dispositions_to_device[cj.cronjob_dispositions[jobnum]]
   local disposition_end = cj.cronjob_dispositions[jobnum]
   local disposition_action_end = dispositions_to_action[disposition_end]
   local device_end = dispositions_to_device[disposition_end]

   local parsed_schedule_end = parse(cj.cronjob_schedules[jobnum])
   local clear_begin = next(parsed_schedule_begin)
   local clear_end = next(parsed_schedule_end)
   local held = {}
   for k,v in ipairs(cj.cronjob_dispositions) do
      if v == disposition_end then
	 local parsed_possible_conflict = parse(cj.cronjob_schedule[k])
	 local possible_conflict_begin = next(parsed_possible_conflict)
	 if possible_conflict_begin >= clear_begin and possible_conflict_begin <= clear_end then
	    hold_job(cj,k,md5sum_begin.." "..md5sum_end)
	    table.insert(held, k)
	 end
      end
   end
   table.insert(cj.cron_all,schedule_end.." "..smart_device_client_cmd.." unhold "..array_to_string(held).." delete "..md5sum_begin.." "..md5sum_end)
   submit_crontab(cj.cron_all)     
end

local function unhold_jobs_delete_jobs(unhold_str,delete_str)
   local cj = get_cron_jobs()
   for md5sum in unhold_str:gmatch("%w+") do
      unhold_job(cj, md5sum)
   end
   local jobs_to_delete_linenums = {}
   for md5sum in delete_str:gmatch("%w+") do
      table.insert(jobs_to_delete_linenums, cj.cronjob_md5sumhexa_to_linenum[md5sum])
   end

   -- bubbleSortAssociatedArraysReverse(jobs_to_delete_linenums)
   -- for _,v in ipairs(jobs_to_delete_linenums) do
   --    table.remove(cj.cron_all,v)
   -- end
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

   for k,v in ipairs(cron.cronjob_dispositions) do
      if k:match("#%s*tmp%s*$") then
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


function maxArrayValueAndItsKey(t, fn)
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
      pp(ins(cj))
      pp(dispositions_cmdline[1][1])  -- 1 is off and 2 is on
      for k,v in ipairs( cj.cronjob_dispositions ) do
	 if v == dispositions_cmdline[devicenum][1] or v == dispositions_cmdline[devicenum][2] then
	    table.insert(cron_in_the_running_list,k)
	    local a = parse(cj.cronjob_schedules[k])
	    
	    pp(cj.cronjob_schedules[k])
	    local c = prev(a)
	    table.insert(cron_in_the_running_list_times,c)
	 end
      end
      local k,v = maxArrayValueAndItsKey(cron_in_the_running_list_times, function(a,b) return a < b end)
      pp("on boot we must execute the following:")
      pp(cj.cronjob_dispositions[cron_in_the_running_list[k]])  
   end
end

local function tbl_to_schedule_string (tbl)
   if not tbl.hour then
      tbl.hour = "*"
   end
   if not tbl.min then
      tbl.min = "*"
   end
   if not tbl.day then
      tbl.day = "*"
   end
   if not tbl.month then
      tbl.month = "*"
   end

   local dow = tbl.dow_recurring_written_out
   if not dow then 
      dow = "?"
   end
   schedule_string = "0 "..tbl.min.." "..tbl.hour.." "..tbl.day.." "..tbl.month.." "..dow.." "

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
   local new_cronline_begin_md5 = md5.sumhexa(new_cronline)
   new_cronline = new_cronline.." #TMP"
   table.insert(cj.cron_all,new_cronline)
   pp("adding new cronline: "..new_cronline)
   if tbl_end then
      local new_schedule_end = tbl_to_schedule_string(tbl_end)
      local new_cronline = new_schedule_end.." "..disposition_begin
      local new_cronline_end_md5 = md5.sumhexa(new_cronline)
      new_cronline = new_cronline.." #TMP"
      table.insert(cj.cron_all,new_cronline)
      table.insert(cj.cron_all,new_schedule_begin.." "..smart_device_client_cmd.." clear schedule for "..new_cronline_begin_md5.." "..new_cronline_end_md5)
      pp("also adding new cronline: "..new_cronline)
      pp("also adding yet another croline: "..new_cronline_begin_md5.." "..new_cronline_end_md5)
   end
   
end

local function flag_error(msg,client)
   client:send(msg)
end


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
      if line == "turn off wifi" or line == "turn wifi off" or line == "disable wifi" then
	 --	os.execute(dispositions_cmdline["wifi"]["off"])
	 pp("turn off wifi")
      elseif line:sub(1,4) == "list" then
	 tmphandle = io.popen("crontab -l 2>" .. errormsg_file)
	 result = tmphandle:read("*a")
	 tmphandle:close()
	 if not result then
	    client:send("no results\n")	   
	    tmphandle = io.open(errormsg_file, "rb")
	    result = tmphandle.lines
	    for result in io.lines(file) do 
	       client:send(result .. "\n")	   
	    end
	 else	   
	    client:send(result .. "\n")
	 end
      -- elseif line == "turn on wifi" or line == "turn wifi on" or line == "enable wifi" then
      -- 	 --	os.execute(dispositions_cmdline["wifi"]["on"])
      -- 	 pp("enable wifi")
      elseif starts_with(line,"delete old") then
	 delete_old_cron_jobs()
      elseif starts_with(line,"test") then
	 client:send("hello there")
	 pp("testing: hello there")
      elseif starts_with(line, "unhold all") then
	 unhold_all_jobs()
      elseif starts_with(line, "hold all") then
	 hold_all_jobs()
      elseif starts_with(line, "clear") then  -- clear schedule for
	 local md5sum_begin, md5sum_end = line:match("^clear schedule for %s*(%x+)%s*[, ]?%s*(%x+)%s*$")
	 if md5sum_begin and md5sum_end then
	    clear_schedule_for(md5sum_begin,md5sum_end)
	 end
      elseif starts_with(line, "unhold") or starts_with(line, "delete") then
	 local unhold_str = line:match("unhold (.*) delete")
	 if not unhold_str then
	    unhold_str = line:match("unhold (.*)$")
	 end
	 local delete_str = line:match("delete (.*) unhold")
	 if not delete_str then
	    delete_str = line:match("delete (.*)$")
	 end	    
	 unhold_jobs_delete_md5(unhold_str, delete_str)
	 
      else     ---- variant commands start here ----------------------------------------------------------------------------------
	 local original_predicate, pos_original_predicate, pos_original_predicate_ends
	 local no_device_was_specified = false
	 local action, device_in_question, device_number, disposition_state, disposition_state_num, temp_value_holder
	 local month,day,year,hour,min,second,week,weekstart_day,day_of_the_year, military_time,dow_week
	 local is_disposition_state
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
		  
	       else
		  local _
		  _,pos_original_predicate_ends = find(device_in_question)
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
	    pp("disposition_state_num = "..disposition_state_num)
	    pp("disposition = "..dispositions_cmdline[device_number][disposition_state_num])
	
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
	    line = trim5(line)
	    line = " "..line.." "
	    
	    local new_line,dow_recurring_string = extract_dow_recurring(line)
	    if new_line and new_line ~= "" then
	       line = new_line
	    end
	    line = line:gsub("/","-")
	    
	    pp("line after removal: "..line)
	    local possible_disposition_state_num = actions_to_disposition_number[action]	
	    if possible_disposition_state_num ~= 0 then   -- disable or enable
	       disposition_state_num = possible_disposition_state_num
	    end
	    

	    pp(action,disposition,device_in_question, pos_original_predicate)     
	    
	    line = line:gsub("%s+"," ")  -- remove_extra_spaces(line)
	    line = trim5(line)
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
	    -- find duration_phrase
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
	    
	    if not (date_in_question_tbl.day and date_in_question_tbl.month and date_in_question_tbl.year) then 
	       local dow_in_question = date_in_question_tbl.dow_written_out
	       if dow_in_question then
		  tmp_tbl = date_of_next_dow(dow_in_question)
		  for k,v in pairs(date_in_question_tbl) do
		     tmp_tbl[k] = v
		  end
		  date_in_question_tbl  = tmp_tbl
	       elseif merge_stuff_following_keyword(date_in_question_by_duration_keywords[1], line, tmp_tbl, in_future_time_parser, os.date("*t")) then
		  tblShallow_fill_in_missing(date_in_question_tbl,tmp_tbl)
	       else -- if all else fails try to parse the line, minus any date_end_range parts, as the date_in_question
		  pp("if all else fails try to parse the line, minus any date_end_range parts, as the date_in_question")
		  local line_without_end_range_info = leave_out_date_range_ends_info(line)	       
		  date_in_question_tbl = variant_date_parser(line_without_end_range_info) or date_in_question_tbl  
		  if not (date_in_question_tbl.day and date_in_question_tbl.month and date_in_question_tbl.year) then
		     local dow_written_out  = find_dow(line_without_end_range_info)
		     if dow_written_out then
			tmp_tbl = date_of_next_dow(dow_written_out)
			for k,v in pairs(date_in_question_tbl) do
			   tmp_tbl[k] = v
			end
			date_in_question_tbl  = tmp_tbl
		     else 
			-- assume today
			local now_tbl = os.date("*t")
			tblShallow_fill_in_missing(now_tbl,date_in_question_tbl)
			date_in_question_tbl = now_tbl
		     end
		  end	    
	       end   -- dow written out condition ends here --
	    end  -- doesnt contain day month and year condition ends here --
	    date_in_question_tbl.dow_recurring_written_out = dow_recurring_string
	    pp("date_in_question_tbl")
	    pp(date_in_question_tbl)
	    if date_in_question_tbl.now then
	       pp("now flag invoked: turning wifi "..disposition_state_num) --debug
	       --	    os.execute(dispositions_cmdline[device_number][disposition_state_num])
	    end
	    
	    for _, keyword in ipairs(date_range_ends_keywords) do
	       merge_stuff_following_keyword(keyword, line, date_range_ends_tbl, variant_date_parser)
	    end	
	    pp("date_range_ends_tbl")
	    pp(date_range_ends_tbl)
	    
	    --	local date_in_question_in_seconds = os.time(date_in_question_tbl)
	    --	 pp(date_in_question_in_seconds)
	    if is_empty(date_range_ends_tbl) then  -- look for duration
	       date_range_ends_tbl = tblShallow_copy(date_in_question_tbl)
	       for _, keyword in ipairs(duration_keywords) do
		  two_part_cmd = true
		  date_range_ends_tbl = merge_stuff_following_keyword(keyword, line, date_range_ends_tbl, in_future_time_parser, date_in_question_table) or nil  -- ok this is incorrect for more than 1 keyword
		  
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
	       elseif not (date_range_ends_tbl.day and date_range_ends_tbl.month and date_range_ends_tbl.year) then  -- assume it maybe lies on same month day and/or year as date in question
		  tblShallow_fill_in_missing(date_range_ends_tbl, date_in_question_tbl)
		  
	       end
	       pp("final date_range_ends:")
	       pp(ins(date_range_ends_tbl))
	    end  -- is empty date_range_ends_tbl condition ends here --
	    pp("dispositions_state_num")
	    pp(dispositions_state_num)
	    add_new_schedule(date_in_question_tbl,dispositions_cmdline[device_number][disposition_state_num], date_range_ends_tbl, dispositions_cmdline[device_number][disposition_state_num % 2 + 1])
	    --	 if two_part_cmd then
	    --	 end
	 end -- else no action ends here --
      end  -- else variant command ends here --
   end  -- else not err ends here --
   pp(ins(keywords_used_array))
   pp(ins(keywords_pos_array))  
   client:close()
end -- while ends here --


-- line:find(date_in_question_by_duration_keywords[1]) then
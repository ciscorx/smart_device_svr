#!/usr/local/bin/luajit

-- The first argument can optionally be the ip address of
-- smart_device_svr.lua, or else its assumed to reside at localhost

local host, port = "127.0.0.1", 29998
local args_line = ""
for _,v in ipairs(arg) do
   if _ == 1 then
      local ip4, ip6ext = v:match("(%d+%.%d+%.%d+%.%d+)([%.%d]*)")
      if ip6ext and ip6ext ~= "" then
	 host = ip4..ip6
      elseif ip4 then
	 host = ip4
      else      
	 args_line = args_line.." "..v
      end
   else
      args_line = args_line.." "..v
   end
end


local socket = require("socket")
local tcp = assert(socket.tcp())

local msg = args_line.."\n"
tcp:connect(host, port)
-- tcp:send(string.format("%q",arg[1]));
print(msg)
tcp:send(msg)

while true do
    local s, status, partial = tcp:receive()
    print(s or partial)
    if status == "closed" then break end
end
tcp:close()

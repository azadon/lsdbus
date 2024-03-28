#!/usr/bin/lua

local u = require("utils")
local lsdb = require("lsdbus")
local common = require("lsdbus.common")

local fmt = string.format

local function starts_with(str, start)
   return string.sub(str, 1, string.len(start)) == start
end

local function ends_with(str, ends)
   return string.sub(str, -1, string.len(ends)) == ends
end

local function errexit(code, format, ...)
    print(fmt(format, ...)); os.exit(code)
end

local is_stdif = {
   ['org.freedesktop.DBus.Properties']=true,
   ['org.freedesktop.DBus.Introspectable']=true,
   ['org.freedesktop.DBus.Peer']=true,
}

local table_size = function (t)
   local tsize = 0
   for _, _ in pairs(t) do tsize = tsize + 1 end

   return tsize
end

local all_interface_empty = function (interfaces, skipped_interfaces)
   for _, i in ipairs(interfaces) do
      if skipped_interfaces[i.name] == nil
            and  (table_size(i.properties)
                  or table_size(i.methods)
                  or table_size(i.signals))
      then
         return false
      end
   end
   return true
end

local function ttp(t, ind)
   for k, v in pairs(t) do
      if type(v) == 'table' then
         print(fmt("%s%s", ind, k))
         local tmpind = ind .. '  '
         if k == 'Properties' then
            for n, ptab in pairs(v) do print(fmt("%s%s", tmpind, common.prop_tostr(n, ptab))) end
         elseif k == 'Signals' then
            for n, stab in pairs(v) do print(fmt("%s%s", tmpind, common.sig_tostr(n, stab))) end
         elseif k == 'Methods' then
            for n, mtab in pairs(v) do print(fmt("%s%s", tmpind, common.met_tostr(n, mtab))) end
         else
            ttp(v, tmpind)
         end
      else
         print(fmt("%s%s: %q", ind, k, v))
      end
   end
end

local function introspect_objects_to_table(objects)
   local t = {}

   for _,o in ipairs(objects) do
      if all_interface_empty(o.node.interfaces, is_stdif) then goto skipnode end

      t[o.path] = {}
      for _,i in ipairs(o.node.interfaces) do
         if is_stdif[i.name] then goto continue end
         if table_size(i.properties) == 0 and  table_size(i.methods) == 0 and table_size(i.signals) then goto continue end

         t[o.path][i.name] = {}
         if table_size(i.methods) > 0 then
            t[o.path][i.name]['Methods'] = {}
            for mname, mtab in pairs(i.methods) do
               t[o.path][i.name]['Methods'][mname] = mtab
            end
         end

         if table_size(i.properties) > 0 then
            t[o.path][i.name]['Properties'] = {}
            for pname, ptab in pairs(i.properties) do
               t[o.path][i.name]['Properties'][pname] = ptab
            end
         end

         if table_size(i.signals) > 0 then
            t[o.path][i.name]['Signals'] = {}
            for sname, stab in pairs(i.signals) do
               t[o.path][i.name]['Signals'][sname] = stab
            end
         end

         ::continue::
      end
      ::skipnode::
   end

   return t
end

local function get_services(dbus_proxy)
   local function cmd_from_pid(pid)
      local f = assert(io.open(fmt("/proc/%i/comm", pid), 'r'))
      return string.gsub(f:read('*a'), '\n$', '')
   end

   local res = {}
   local names = dbus_proxy('ListNames')

   for _,n in ipairs(names) do
      local creds = dbus_proxy('GetConnectionCredentials', n)
      local uid = dbus_proxy('GetNameOwner', n)
      local cmd = cmd_from_pid(creds.ProcessID)
      res[#res+1] = { wid=n, uid=uid, cmd=cmd, pid=creds.ProcessID }
   end

   table.sort(res, function(x, y) return x.wid<y.wid end)
   return res
end

-- ----------------------------------------------
local r = require 'readline'
r.set_options{ keeplines=1000, histfile='/tmp/.synopsis_history' }
r.set_readline_name('lsdbctl')

local reserved_words = {
   main = {'help', 'ls', 'select', 'exit'},
   service = {'help', 'ls', 'exit'},
   slist = {}
}

r.set_complete_list(reserved_words.main)
-- ------------------------------------------------

local completer_function = function(text, from, to)
   local completer = function (s, f, t, words)
      local incomplete = string.sub(s, f, t)
      local matches = {}
      for _, v in ipairs(words) do
         if incomplete == string.sub(v, 1, #incomplete) then
            matches[1 + #matches] = v
         end
      end
      return matches
   end

   if from == 1 then
      return completer(text, from, to, reserved_words.main)
   else
      local cmd = string.sub(text, 1, from -1):gsub('%s+', '')
      if cmd == 'select' then
         return completer(text, from, to, reserved_words.slist)
      end
   end

   return {}
end
r.set_complete_function(completer_function)


----------------------------------------
local b = lsdb.open('default_system')
local p = lsdb.proxy.new(b, 'org.freedesktop.DBus', '/', 'org.freedesktop.DBus')
local services = get_services(p)
----------------------------------------
local function services2names(s)
   local t = {}
   for _, v in pairs(s) do
      table.insert(t, v['wid'])
   end

   return t
end

reserved_words.slist = services2names(services)

local prompt = '> '
local context = 'main'
local objs = {}
-- -------------------------------------
while true do
   local cmd = r.readline(prompt)

   if cmd == 'exit' and context == 'main' then break end

   if cmd == 'exit' then
      context = 'main'
      prompt = '> '
   end
   if cmd == 'ls' then
      if context == 'main' then
         services = get_services(p)
         reserved_words.slist = services2names(services)

         local hdr = { 'wid', 'uid', 'cmd', 'pid' }
         local _, rows = u.tabulate(services, hdr)
         u.write_table(io.stdout, hdr, rows, {count=false})
      elseif context == 'service' then
         ttp(introspect_objects_to_table(objs), '  ')
      end
   elseif cmd == 'help' then
      print('Please select one of the commands')
      print('   help             - print this help')
      print('   exit             - exit this program')
      print('   list             - list all services on the "default_system" bus')
      print('   select SERVICE   - connect to service')
   elseif starts_with(cmd, 'select') then
      local service = string.sub(cmd, string.len('select')+1):gsub('%s+', '')
      objs = common.introspect(b, service)
      prompt = fmt('[%s]> ', service)
      context = 'service'
   end
end


r.save_history() ; os.exit()

local lsdb = require("lsdbus")

local evsrc
local enabled = 1

local function toggle()
   if enabled==1 then enabled=0 else enabled=1 end
   print("enabled:", enabled)
   evsrc:set_enabled(enabled)
end

local function loop(...) print(os.date(), ...) end
local function exit(b, sig) b:exit_loop() end

local b = lsdb.open('user')
b:add_signal("SIGINT", exit)
b:add_signal("SIGUSR1", toggle)
evsrc = b:add_periodic(1*1000^2, 0, loop)
b:loop()

print("exited loop, shutting down")

local root=arg[1] or "."
package.path=root.."/src/ue4ss/Mods/shared/?.lua;"..package.path
local passed=0
local function test(name,f)
    local ok,err=pcall(f)
    if not ok then io.stderr:write("FAIL "..name..": "..tostring(err).."\n");os.exit(1) end
    passed=passed+1;print("PASS "..name)
end
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local M=require("NoxyForge.mathx")
local L=require("NoxyForge.lifecycle")
test("zero-distance attraction is finite",function()
 local v=M.attraction({X=0,Y=0,Z=0},{X=0,Y=0,Z=0},{radius=100,acceleration=100,softness=10})
 eq(v.X,0);eq(v.Y,0);eq(v.Z,0)
end)
test("force cap also limits tangential acceleration",function()
 local v=M.attraction({X=1,Y=1,Z=2},{X=0,Y=0,Z=0},{radius=100,acceleration=10,softness=10,swirl=10000})
 assert(math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z)<=10.000001)
end)
test("out-of-range actors get no impulse",function()
 eq(M.attraction({X=500,Y=0,Z=0},{X=0,Y=0,Z=0},{radius=10}).X,0)
end)
test("hostile non-finite configuration is rejected",function()
 eq(M.attraction({X=1,Y=0,Z=0},{X=0,Y=0,Z=0},{radius=0}),nil)
 eq(M.attraction({X=0/0,Y=0,Z=0},{X=0,Y=0,Z=0}),nil)
end)
test("world changes invalidate pending callbacks",function()
 local l=L.new();l:transition("A");local calls=0;local cb=l:guard(function()calls=calls+1 end)
 cb();l:transition("B");cb();eq(calls,1)
end)
test("cleanup reverses acquisition and isolates failures",function()
 local l=L.new();local order={}
 l:own("p","a",function()order[#order+1]="a" end)
 l:own("p","b",function()error("cleanup fails")end)
 l:own("p","c",function()order[#order+1]="c"end)
 local errors=l:cleanup("p");eq(#errors,1);eq(table.concat(order),"ca");eq(#l.cleanups,0)
end)
test("reentrant cleanup runs each resource once",function()
 local l=L.new();local calls=0
 l:own("p","a",function()calls=calls+1;l:cleanup("p")end)
 l:cleanup("p");l:cleanup("p");eq(calls,1)
end)
test("duplicate ownership cannot silently replace cleanup",function()
 local l=L.new();assert(l:own("p","a",function()end));eq(l:own("p","a",function()end),nil)
end)
-- Mock only the engine boundary; lifecycle and plugin logic remain real.
package.loaded["NoxyForge.ue4ss"]={new=function() error("test must inject bridge") end}
local F=require("NoxyForge.framework")
local function fixture()
 local state={now=0,world="A",player_id="player",pawn={name="Willie_BP_C"},deferred={},logs={},cancelled=0}
 function state.pawn:GetClass() return {GetFName=function()return {ToString=function()return "Willie_BP_C"end}end} end
 local b={}
 function b:valid(o)return o~=nil and not o.dead end
 function b:context()return {world_id=state.world,pawn=state.pawn,player_id=state.player_id}end
 function b:clock()return state.now end
 function b:log(c,m)state.logs[#state.logs+1]={c,m}end
 function b:loop(ms,cb)state.loop=cb;return function()state.cancelled=state.cancelled+1 end end
 function b:defer(cb)state.deferred[#state.deferred+1]=cb end
 function b:key(k,cb)state.keys=state.keys or {};state.keys[k]=cb end
 local c={schema_version=1,profile="half_sword",interval_ms=50,max_targets=16,max_owned_actors=8,keybinds=false,
 protection=false,strength=false,standing=false,blade_multiplier=1,plugins={},
 black_hole={radius=700,acceleration=350,softness=120,swirl=100,duration=10,size=1.2}}
 local a=F.new(c,b)
 return a,state,b
end
test("one failing plugin cannot stop another",function()
 local a,s=fixture();local calls=0
 a:register({id="bad",update=function()error("bad plugin")end})
 a:register({id="good",update=function()calls=calls+1 end})
 a:start();s.loop();s.loop();eq(calls,2);eq(a.plugins.bad.enabled,false)
end)
test("shutdown cancels timer and gates previously queued work",function()
 local a,s=fixture();local calls=0;a:start();s.loop()
 a:queue(function()calls=calls+1 end);a:stop();s.loop()
 for _,cb in ipairs(s.deferred)do cb()end
 eq(calls,0);eq(s.cancelled,1);eq(a.life.state,"stopped")
end)
test("shutdown requested by one command gates remaining commands and updates",function()
 local a,s=fixture();local updates,calls=0,0
 a:register({id="p",update=function()updates=updates+1 end})
 a:start();s.loop();eq(updates,1)
 a:queue(function(app)app:stop()end)
 a:queue(function()calls=calls+1 end)
 s.loop();eq(calls,0);eq(updates,1)
end)
test("shutdown key works without valid pawn context",function()
 local a,s=fixture();a.config.keybinds=true;s.pawn=nil;s.player_id=nil
 a:start();s.loop();s.keys.F10();s.keys.F10()
 local index=1
 while index<=#s.deferred do s.deferred[index]();index=index+1 end
 eq(a.life.state,"stopped");eq(s.cancelled,1);eq(a.started,false)
end)
test("world transition discards old commands",function()
 local a,s=fixture();a:start();s.loop();local calls=0
 a:queue(function()calls=calls+1 end);s.world="B";s.loop();eq(calls,0)
end)
test("bounded command queue reports overflow",function()
 local a=fixture();for _=1,32 do assert(a:queue(function()end))end
 eq(a:queue(function()end),nil)
end)
test("faulted plugin key cannot schedule new native work",function()
 local a,s=fixture();local calls=0
 a:register({id="p",initialize=function(self,app)app:key("F7",function()calls=calls+1 end)end,update=function()error("failed")end})
 a:start();s.loop();s.keys.F7();s.loop();eq(calls,0)
end)
test("fault restores snapshots before owned-resource cleanup",function()
 local a,s=fixture();local state={value="original"};local order={}
 a:register({id="p",update=function(self,app)
     state.value="modified"
     app:own("p","effect",function()eq(state.value,"original");order[#order+1]="cleanup"end)
     error("mid-update failure")
 end,shutdown=function()state.value="original";order[#order+1]="shutdown"end})
 a:start();s.loop();eq(state.value,"original");eq(table.concat(order,","),"shutdown,cleanup")
 eq(#a.life.cleanups,0);s.loop();eq(#order,2)
end)
test("failed fault-shutdown still cleans resources and isolates other plugins",function()
 local a,s=fixture();local cleanups,shutdowns,updates=0,0,0
 a:register({id="bad",initialize=function(self,app)
     app:own("bad","effect",function()cleanups=cleanups+1 end)
 end,update=function()error("update failure")end,
 shutdown=function()shutdowns=shutdowns+1;error("shutdown failure")end})
 a:register({id="good",update=function()updates=updates+1 end})
 a:start();s.loop();s.loop();eq(cleanups,1);eq(shutdowns,1);eq(updates,2)
end)
test("shutdown failure is not recursively retried",function()
 local a,s=fixture();local shutdowns,cleanups=0,0
 a:register({id="p",initialize=function(self,app)
     app:own("p","effect",function()cleanups=cleanups+1 end)
 end,shutdown=function()shutdowns=shutdowns+1;error("shutdown failure")end})
 a:start();s.loop();a:stop()
 for _,cb in ipairs(s.deferred)do cb()end
 eq(shutdowns,1);eq(cleanups,1);eq(a.life.state,"stopped")
end)
test("same-world pawn replacement invalidates commands and guarded callbacks",function()
 local a,s=fixture();local commands,callbacks,cleanups,changes=0,0,0,0
 a:register({id="p",player_changed=function(self,app,context,previous)
     eq(context.player_id,"replacement");eq(previous.player_id,"player");changes=changes+1
 end})
 a:start();s.loop();local epoch=a.life.epoch
 local guarded=a.life:guard(function()callbacks=callbacks+1 end)
 a:own("p","effect",function(reason)eq(reason,"player_changed");cleanups=cleanups+1 end)
 a:queue(function()commands=commands+1 end)
 s.player_id="replacement";s.loop();guarded()
 eq(commands,0);eq(callbacks,0);eq(cleanups,1);eq(changes,1);eq(a.life.epoch,epoch+1)
 s.loop();eq(changes,1)
end)
test("same-world pawn replacement restores legacy plugin snapshots",function()
 local a,s=fixture();local restores=0
 a:register({id="legacy",world_changed=function()restores=restores+1 end})
 a:start();s.loop();eq(restores,1)
 s.player_id="replacement";s.loop();eq(restores,2)
 s.player_id=nil;s.loop();eq(restores,3)
end)
local Settings=require("NoxyForge.settings")
test("configuration rejects invalid native transform values",function()
 local a=fixture();a.config.black_hole.size=0/0;eq(Settings.validate(a.config),nil)
end)
print(string.format("%d tests passed",passed))

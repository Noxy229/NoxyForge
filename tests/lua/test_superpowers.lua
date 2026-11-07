-- Engine boundary fixture; actual plugin snapshot and multiplier logic executes.
local root=arg[1] or "."
package.path=root.."/src/ue4ss/Mods/shared/?.lua;"..package.path
local passed=0
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function test(name,callback)
 local ok,message=pcall(callback)
 if not ok then io.stderr:write("FAIL "..name..": "..tostring(message).."\n");os.exit(1) end
 passed=passed+1;print("PASS "..name)
end
local function fixture()
 local plugin=dofile(root.."/src/ue4ss/Mods/shared/NoxyForge/superpowers.lua")
 local bridge={writes={},logs={}}
 function bridge:valid(object)return type(object)=="table" and not object.dead end
 function bridge:id(object)return object.id end
 function bridge:get(object,property)if self:valid(object) then return object[property] end end
 function bridge:set(object,property,value)
  if not self:valid(object) or type(object[property])~=type(value) then return nil,"invalid property" end
  self.writes[#self.writes+1]={object,property,value};object[property]=value;return true
 end
 function bridge:log(code,message)self.logs[#self.logs+1]={code,message}end
 local app={bridge=bridge,config={keybinds=true,blade_multiplier=1},keys={},
 profile={properties={right_weapon="Weapon R",left_weapon="Weapon L"},weapon_sharpness={"Edge Sharpness","Tip Sharpness"}}}
 function app:key(key,callback)self.keys[key]=callback end
 local context={pawn={id="player"}}
 plugin:initialize(app)
 return plugin,app,context
end
local function weapon(id,edge,tip)return {id=id,["Edge Sharpness"]=edge,["Tip Sharpness"]=tip}end

local function settle(p,a,c)
 for _=1,16 do p:update(a,c,.05) end
end

test("F5 multiplies both held weapons once and restores exact baselines",function()
 local p,a,c=fixture();local right=weapon("r",2.5,0);local left=weapon("l",1500,3)
 c.pawn["Weapon R"]=right;c.pawn["Weapon L"]=left
 a.keys.F5(a);eq(a.config.blade_multiplier,10)
 settle(p,a,c);p:update(a,c,.05)
 eq(right["Edge Sharpness"],25);eq(right["Tip Sharpness"],0)
 eq(left["Edge Sharpness"],10000);eq(left["Tip Sharpness"],30)
 a.keys.F5(a);eq(a.config.blade_multiplier,1)
 eq(right["Edge Sharpness"],2.5);eq(left["Edge Sharpness"],1500)
 eq(next(p.weapon_snapshots),nil)
end)
test("dropped weapon restores before replacement and unheld weapon is untouched",function()
 local p,a,c=fixture();local old=weapon("old",4,2);local replacement=weapon("new",5,1)
 local unrelated=weapon("unrelated",8,8)
 c.pawn["Weapon R"]=old;a.config.blade_multiplier=10;settle(p,a,c)
 c.pawn["Weapon R"]=replacement;settle(p,a,c)
 eq(old["Edge Sharpness"],4);eq(replacement["Edge Sharpness"],50)
 eq(unrelated["Edge Sharpness"],8)
 c.pawn["Weapon R"]=nil;p:update(a,c,.05)
 eq(replacement["Edge Sharpness"],5);eq(next(p.weapon_snapshots),nil)
end)
test("invalid numeric sharpness and invalid multipliers never write garbage",function()
 local p,a,c=fixture();local w=weapon("w",0/0,math.huge)
 c.pawn["Weapon R"]=w;a.config.blade_multiplier=10;settle(p,a,c)
 eq(#a.bridge.writes,0)
 w["Edge Sharpness"]=-3;w["Tip Sharpness"]="not numeric";p:update(a,c,.05)
 eq(#a.bridge.writes,0)
 w["Edge Sharpness"]=2;w["Tip Sharpness"]=1;settle(p,a,c)
 eq(w["Edge Sharpness"],20)
 a.config.blade_multiplier=0/0;p:update(a,c,.05);eq(w["Edge Sharpness"],2)
 eq(next(p.weapon_snapshots),nil)
end)
test("world change pawn replacement and shutdown each restore held weapons",function()
 for _,method in ipairs({"world_changed","player_changed","shutdown"}) do
  local p,a,c=fixture();local w=weapon("w",3,7)
  c.pawn["Weapon R"]=w;a.config.blade_multiplier=10;settle(p,a,c)
  p[method](p,a);eq(w["Edge Sharpness"],3);eq(w["Tip Sharpness"],7)
  eq(next(p.weapon_snapshots),nil)
 end
end)
test("dual hand references cannot compound and dead weapons are skipped",function()
 local p,a,c=fixture();local w=weapon("w",2,4)
 c.pawn["Weapon R"]=w;c.pawn["Weapon L"]=w;a.config.blade_multiplier=10
 settle(p,a,c);eq(w["Edge Sharpness"],20);assert(#a.bridge.writes>=2 and #a.bridge.writes<=4)
 w.dead=true;p:update(a,c,.05);eq(next(p.weapon_snapshots),nil)
end)
test("weapon restoration is independent of player field toggles",function()
 local p,a,c=fixture();local w=weapon("w",2,4)
 c.pawn["Weapon R"]=w;a.config.blade_multiplier=10;settle(p,a,c)
 a.keys.F6(a);eq(w["Edge Sharpness"],20)
 p:shutdown(a);eq(w["Edge Sharpness"],2)
end)
test("warm-up captures initialized values and dropping pending weapons writes nothing",function()
 local p,a,c=fixture();local w=weapon("spawned",0,0)
 c.pawn["Weapon R"]=w;a.config.blade_multiplier=10
 for _=1,7 do p:update(a,c,.05) end
 eq(#a.bridge.writes,0);eq(next(p.weapon_snapshots.spawned.values),nil)
 w["Edge Sharpness"]=72.25;w["Tip Sharpness"]=83.3
 for _=1,7 do p:update(a,c,.05) end
 eq(#a.bridge.writes,0)
 p:update(a,c,.05)
 eq(w["Edge Sharpness"],722.5);eq(w["Tip Sharpness"],833)
 eq(p.weapon_snapshots.spawned.values["Edge Sharpness"],72.25)
 p:shutdown(a);eq(w["Edge Sharpness"],72.25);eq(w["Tip Sharpness"],83.3)
 local pending=weapon("pending",0,0);c.pawn["Weapon R"]=pending
 p:update(a,c,.05);local writes=#a.bridge.writes
 c.pawn["Weapon R"]=nil;p:update(a,c,.05)
 eq(#a.bridge.writes,writes);eq(next(p.weapon_snapshots),nil)
end)
print(passed.." superpowers tests passed")

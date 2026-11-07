local mathx=require("NoxyForge.mathx")
local S={}
local function bounded(value,low,high,name)
    if not mathx.finite(value) or value<low or value>high then return nil,"invalid setting: "..name end
    return true
end
function S.validate(c)
    if type(c)~="table" or c.schema_version~=1 then return nil,"unsupported config schema" end
    if type(c.profile)~="string" or not c.profile:match("^[%w_]+$") then return nil,"invalid game profile" end
    for name,bounds in pairs({interval_ms={16,1000},max_targets={1,64},max_owned_actors={1,32},blade_multiplier={1,20}}) do
        local ok,err=bounded(c[name],bounds[1],bounds[2],name);if not ok then return nil,err end
    end
    for _,name in ipairs({"protection","strength","standing","keybinds"}) do
        if type(c[name])~="boolean" then return nil,"expected boolean: "..name end
    end
    if type(c.black_hole)~="table" then return nil,"missing black_hole settings" end
    for name,bounds in pairs({radius={50,2500},acceleration={0,2000},softness={1,1000},swirl={0,2000},duration={.5,60},size={.1,20}}) do
        local ok,err=bounded(c.black_hole[name],bounds[1],bounds[2],"black_hole."..name);if not ok then return nil,err end
    end
    if c.black_hole.softness>c.black_hole.radius then return nil,"softness exceeds radius" end
    if type(c.plugins)~="table" or #c.plugins>16 then return nil,"invalid plugin list" end
    local seen={}
    for _,name in ipairs(c.plugins) do
        if type(name)~="string" or not name:match("^[%w_%.]+$") or name:find("..",1,true) or seen[name] then return nil,"invalid or duplicate plugin" end
        seen[name]=true
    end
    return true
end
return S

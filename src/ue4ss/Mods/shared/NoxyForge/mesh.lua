-- Copyright (c) 2026 Noxy229. SPDX-License-Identifier: MIT
local Geometry=require("NoxyForge.geometry")
local M={}
local function finite(n) return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge end
local function vector(v)
    return type(v)=="table" and finite(v.X) and finite(v.Y) and finite(v.Z)
end
local function identity()
    return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
local function valid(bridge,object)
    local ok,result=pcall(function() return bridge:valid(object) end)
    return ok and result==true
end
local function log(bridge,message)
    if type(bridge.log)=="function" then pcall(function()bridge:log("MESH",message)end) end
end
-- Only call this service from the framework's GameThread execution path.
function M.destroy(bridge,handle)
    if not handle or handle.closed then return true end
    local errors={}
    if valid(bridge,handle.component) and valid(bridge,handle.actor) then
        local ok,err=pcall(function()handle.component:K2_DestroyComponent(handle.actor)end)
        if not ok then errors[#errors+1]="component cleanup: "..tostring(err) end
    end
    if valid(bridge,handle.actor) then
        local ok,err=pcall(function()bridge:destroy(handle.actor)end)
        if not ok then errors[#errors+1]="actor cleanup: "..tostring(err) end
    end
    if #errors>0 then
        local message=table.concat(errors,"; ");log(bridge,message)
        return false,message
    end
    handle.closed=true
    handle.actor=nil;handle.component=nil
    return true
end
local function options_valid(options)
    if type(options)~="table" then return false,"options must be a table" end
    if options.location~=nil and not vector(options.location) then return false,"invalid mesh location" end
    if options.rotation~=nil then
        local r=options.rotation
        if type(r)~="table" or not finite(r.Pitch) or not finite(r.Yaw) or not finite(r.Roll) then return false,"invalid mesh rotation" end
    end
    if options.scale~=nil then
        local s=options.scale
        if type(s)=="number" then s={X=s,Y=s,Z=s} end
        if not vector(s) or s.X<=0 or s.Y<=0 or s.Z<=0 or math.max(s.X,s.Y,s.Z)>1000 then return false,"invalid mesh scale" end
    end
    if options.create_section~=nil and type(options.create_section)~="function" then return false,"create_section must be a function" end
    if options.add_component~=nil and type(options.add_component)~="function" then return false,"add_component must be a function" end
    if options.materials~=nil and type(options.materials)~="table" then return false,"materials must be a table" end
    return true
end
local function material_path(section,index,options)
    local configured=options.materials or {}
    local path=configured[section.name] or configured[index] or section.material_path or options.material_path
    if path==nil then return nil end
    if type(path)~="string" or #path==0 or #path>512 or path:sub(1,1)~="/" or path:find("://",1,true) then
        return nil,"material must name an installed Unreal asset path"
    end
    return path
end
local function create_section(component,index,s)
    -- The reflected four-UV-channel overload has 12 explicit parameters.
    -- Lua tables are marshalled by UE4SS; no raw TArray headers are created.
    component:CreateMeshSection_LinearColor(index,s.positions,s.triangles,s.normals or {},
        s.uv0 or {},s.uv1 or {},s.uv2 or {},s.uv3 or {},s.colors or {},{},false,false)
end
function M.spawn(bridge,context,model,options)
    options=options or {}
    if type(bridge)~="table" or type(bridge.valid)~="function" or type(bridge.find)~="function"
        or type(bridge.destroy)~="function" then return nil,"mesh service requires bridge valid/find/destroy" end
    local ok,err=options_valid(options);if not ok then return nil,err end
    ok,err=Geometry.validate(model,options.limits);if not ok then return nil,err end
    if type(context)~="table" or not valid(bridge,context.world) then return nil,"no valid world for mesh spawn" end
    local sections=model.sections or {model}
    local materials={}
    -- Resolve assets before acquiring any actor/component resources.
    local resolved,resolve_error=pcall(function()
        for i,s in ipairs(sections) do
            local path,path_error=material_path(s,i,options)
            if path_error then error(path_error) end
            if path then
                local material,message=bridge:find(path)
                if not valid(bridge,material) then error(message or "material unavailable: "..path) end
                materials[i]=material
            end
        end
    end)
    if not resolved then return nil,tostring(resolve_error) end
    local class,component_class
    resolved,resolve_error=pcall(function()
        local message
        class,message=bridge:find(options.actor_class_path or "/Script/Engine.Actor")
        if not valid(bridge,class) then error(message or "Actor class unavailable") end
        component_class,message=bridge:find(options.component_class_path or "/Script/ProceduralMeshComponent.ProceduralMeshComponent")
        if not valid(bridge,component_class) then error(message or "ProceduralMeshComponent class unavailable") end
    end)
    if not resolved then return nil,tostring(resolve_error) end
    local location=options.location or {X=0,Y=0,Z=0}
    local rotation=options.rotation or {Pitch=0,Yaw=0,Roll=0}
    local scale=options.scale or {X=1,Y=1,Z=1}
    if type(scale)=="number" then scale={X=scale,Y=scale,Z=scale} end
    local handle={actor=nil,component=nil,closed=false,section_count=#sections,uses_default_material=false}
    function handle:destroy()return M.destroy(bridge,self)end
    local spawned,message=pcall(function()
        handle.actor=context.world:SpawnActor(class,location,rotation)
        if not valid(bridge,handle.actor) then error("SpawnActor returned no valid actor") end
        local actor=handle.actor
        if options.add_component then handle.component=options.add_component(actor,component_class,identity())
        else handle.component=actor:AddComponentByClass(component_class,false,identity(),false) end
        if not valid(bridge,handle.component) then error("AddComponentByClass returned no valid component") end
        local component=handle.component
        component:SetMobility(2)
        local root=actor:K2_GetRootComponent()
        if valid(bridge,root) then root:SetMobility(2) end
        actor:SetActorEnableCollision(false)
        component:SetCollisionEnabled(0)
        -- A native Actor may have had no root when SpawnActor applied its transform.
        if actor:K2_SetActorLocation(location,false,{},true)==false then error("Actor location update failed") end
        if actor:K2_SetActorRotation(rotation,true)==false then error("Actor rotation update failed") end
        actor:SetActorScale3D(scale)
        for i,s in ipairs(sections) do
            (options.create_section or create_section)(component,i-1,s)
            if materials[i] then component:SetMaterial(i-1,materials[i])
            else handle.uses_default_material=true end
        end
    end)
    if not spawned then
        local cleaned,cleanup_error=M.destroy(bridge,handle)
        local error_text=tostring(message)
        if not cleaned then error_text=error_text.."; "..cleanup_error end
        return nil,error_text
    end
    return handle
end
return M

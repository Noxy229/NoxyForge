-- Copyright (c) 2026 Noxy229. SPDX-License-Identifier: MIT
-- GameThread only. Inspects loaded objects; never edits source material assets.
local M={}
local catalogs=setmetatable({},{__mode="k"})
M.sources={
    "https://docs.ue4ss.com/lua-api/global-functions/findallof.html",
    "https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UPrimitiveComponent",
    "https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UMaterialInstanceDynamic",
    "https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UMaterialInstance",
}
local function finite(x)return type(x)=="number" and x==x and x~=math.huge and x~=-math.huge end
local function get(object,key)
    if object==nil then return nil end
    local ok,value=pcall(function()return object[key]end)
    if ok then return value end
end
local function valid(bridge,object)
    local ok,result=pcall(function()return bridge:valid(object)end)
    return ok and result==true
end
local function text(value)
    if type(value)=="string" then return value end
    if value==nil then return nil end
    local ok,result=pcall(function()return value:ToString()end)
    if ok and type(result)=="string" then return result end
end
local function key(name)return name:lower():gsub("[%s_%-%./]","")end
local function name_of(object)
    local ok,name=pcall(function()return object:GetFullName()end)
    if ok and type(name)=="string" then return name:match("^%S+ (.+)$") or name end
    return nil
end
local function identifier(bridge,object)
    if type(bridge.id)=="function" then
        local ok,id=pcall(function()return bridge:id(object)end)
        if ok and id then return tostring(id)end
    end
    return tostring(object)
end
local function log(bridge,code,message)
    if type(bridge.log)=="function" then pcall(function()bridge:log(code,message)end)end
end
local function array_values(array,maximum,callback)
    if array==nil then return end
    local ok,count=pcall(function()return #array end)
    if not ok or not finite(count) or count<0 then return end
    for i=1,math.min(count,maximum) do
        local entry=get(array,i)
        if entry~=nil then callback(entry)end
    end
end
-- These arrays list instance overrides, not every parameter in a cooked shader.
function M.parameters(bridge,source,options)
    options=options or {}
    local vectors,scalars,seen={},{},{}
    local current=source
    for _=1,8 do
        if not valid(bridge,current)then break end
        local id=identifier(bridge,current);if seen[id]then break end;seen[id]=true
        for property,target in pairs({VectorParameterValues=vectors,ScalarParameterValues=scalars})do
            array_values(get(current,property),64,function(entry)
                local info=get(entry,"ParameterInfo")
                local association=get(info,"Association")
                if association==nil or association==0 then
                    local name=text(get(info,"Name") or get(entry,"ParameterName"))
                    if name and #name>0 and #name<=128 and name~="None" then target[name]=true end
                end
            end)
        end
        current=get(current,"Parent")
    end
    return {vectors=vectors,scalars=scalars,complete=false}
end
local function color_parameter(name)
    local k=key(name)
    return k=="color" or k=="colour" or k=="tint" or k=="basecolor" or k=="basecolour"
        or k=="basecolortint" or k=="basecolourtint" or k=="emissivecolor" or k=="emissivecolour"
        or k=="emissioncolor" or k=="glowcolor" or k=="tintcolor" or k=="colortint"
end
local function emission_parameter(name)
    local k=key(name)
    return k=="emissiveintensity" or k=="emissivestrength" or k=="emissivepower"
        or k=="emissionstrength" or k=="emissionintensity" or k=="glowintensity" or k=="glowstrength"
end
local function describe(bridge,source)
    if not valid(bridge,source)then return nil end
    local type_ok,is_material=pcall(function()return source:IsA("/Script/Engine.MaterialInterface")end)
    if not type_ok or is_material~=true then return nil end
    local path=name_of(source)
    if not path then return nil end
    local lower=path:lower()
    if lower:find("default__",1,true)or lower:find("/script/",1,true)then return nil end
    return {source=source,path=path,parameters=M.parameters(bridge,source)}
end
function M.enumerate(bridge,options)
    options=options or {}
    if type(bridge)~="table" or type(options)~="table"then return nil,"bridge/options must be tables"end
    local max=options.max_candidates or 192
    if not finite(max)or max%1~=0 or max<1 or max>512 then return nil,"max_candidates must be between 1 and 512" end
    local env=bridge.env or _G
    if type(env.FindAllOf)~="function"then return {},"FindAllOf unavailable"end
    local candidates,seen={},{}
    local visited=0
    for _,class in ipairs({"MaterialInstanceConstant","MaterialInstanceDynamic","Material"})do
        local ok,objects=pcall(env.FindAllOf,class)
        if ok and type(objects)=="table"then
            for _,object in ipairs(objects)do
                visited=visited+1
                local id=identifier(bridge,object)
                if not seen[id]then
                    seen[id]=true
                    local candidate=describe(bridge,object)
                    if candidate then candidates[#candidates+1]=candidate end
                end
                if visited>=max then return candidates end
            end
        end
    end
    return candidates
end
local function score(role,candidate)
    local path=candidate.path:lower()
    if path:find("decal",1,true)or path:find("postprocess",1,true)or path:find("/ui/",1,true)
        or path:find("widget",1,true)or path:find("landscape",1,true)then return 0 end
    local colors,emission=0,0
    for name in pairs(candidate.parameters.vectors)do if color_parameter(name)then colors=1 end end
    for name in pairs(candidate.parameters.scalars)do if emission_parameter(name)then emission=1 end end
    local value=0
    if role=="core"then
        if path:find("black",1,true)then value=value+100 end
        if path:find("dark",1,true)then value=value+60 end
        value=value+colors*70
    else
        if path:find("emissive",1,true)or path:find("glow",1,true)then value=value+100 end
        if path:find("fire",1,true)or path:find("flame",1,true)then value=value+70 end
        value=value+emission*100+colors*10
    end
    return value
end
local function installed_path(path)
    return type(path)=="string"and #path>0 and #path<=512 and path:sub(1,1)=="/"and not path:find("://",1,true)
end
function M.resolve(bridge,options)
    options=options or {}
    if type(options)~="table"then return nil,"options must be a table"end
    for _,role in ipairs({"core","accretion"})do
        if options[role]~=nil and type(options[role])~="table"then return nil,role.." options must be a table"end
        local cfg=options[role]or {}
        if cfg.path~=nil and not installed_path(cfg.path)then return nil,"invalid installed material path"end
        for _,key in ipairs({"color_parameters","emissive_parameters"})do
            local names=cfg[key]
            if names~=nil then
                if type(names)~="table"then return nil,"invalid configured parameter names"end
                local count=0
                for index,name in pairs(names)do
                    count=count+1
                    if count>32 or type(index)~="number"or index%1~=0 or index<1 or index>32
                        or type(name)~="string"or #name<1 or #name>128 then
                        return nil,"configured parameter names require at most 32 bounded strings"
                    end
                end
                for index=1,count do if names[index]==nil then return nil,"configured parameter names must be dense"end end
            end
        end
        if cfg.intensity~=nil and(not finite(cfg.intensity)or cfg.intensity<0 or cfg.intensity>64)then return nil,"invalid emissive intensity"end
        if cfg.color~=nil then
            if type(cfg.color)~="table"then return nil,"invalid material color"end
            for _,channel in ipairs({"R","G","B","A"})do
                local v=cfg.color[channel]
                if not finite(v)or v<0 or v>(channel=="A"and 1 or 64)then return nil,"invalid material color"end
            end
        end
    end
    local candidates,enumeration_error=options.candidates or {},nil
    if type(candidates)~="table"then return nil,"candidates must be a table"end
    if options.auto==true and options.candidates==nil then
        local cache=catalogs[bridge]
        local cache_key=options.cache_key or "session"
        if not cache or cache.key~=cache_key then
            local found,message=M.enumerate(bridge,options)
            if not found then return nil,message end
            cache={key=cache_key,objects=found,message=message};catalogs[bridge]=cache
        end
        candidates,enumeration_error=cache.objects,cache.message
    end
    local palette={warnings={}}
    if enumeration_error then palette.warnings[#palette.warnings+1]=enumeration_error end
    for _,role in ipairs({"core","accretion"})do
        local cfg=options[role]or {};local chosen
        if cfg.path then
            local ok,source=pcall(function()return bridge:find(cfg.path)end)
            if ok then chosen=describe(bridge,source)end
            if chosen then chosen.selection="configured"else palette.warnings[#palette.warnings+1]=role..": configured material unavailable"end
        elseif options.auto==true or options.candidates~=nil then
            local best=0
            for _,candidate in ipairs(candidates)do
                if type(candidate)=="table"and type(candidate.path)=="string"and type(candidate.parameters)=="table"
                    and type(candidate.parameters.vectors)=="table"and type(candidate.parameters.scalars)=="table"
                    and valid(bridge,candidate.source)then
                    local value=score(role,candidate)
                    if value>=60 and(value>best or value==best and(not chosen or candidate.path<chosen.path))then
                        best=value;chosen=candidate
                    end
                end
            end
            if chosen then
                -- Each role gets its own descriptor; never share mutable result state.
                chosen={source=chosen.source,path=chosen.path,parameters=chosen.parameters,selection="heuristic"}
            end
        end
        palette[role]=chosen or {fallback_gray=true,reason="no compatible configured/loaded material; retain current/default (gray fallback)"}
    end
    return palette
end
function M.clear_cache(bridge)catalogs[bridge]=nil end
local function selected_names(available,predicate,configured,allow_unverified)
    local names={}
    if type(configured)=="table"then
        for _,name in ipairs(configured)do if type(name)=="string"and #name>0 and #name<=128 and (available[name]or allow_unverified)then names[#names+1]=name end end
    else for name in pairs(available)do if predicate(name)then names[#names+1]=name end end end
    table.sort(names);return names
end
function M.apply(bridge,component,options)
    options=options or {}
    if not valid(bridge,component)then return nil,"invalid mesh component"end
    local palette,err=M.resolve(bridge,options);if not palette then return nil,err end
    local report={warnings=palette.warnings,used_default_material=false,originals={},dynamic_instances={}}
    local env=bridge.env or _G
    local function fallback(role,reason)
        report.used_default_material=true
        report[role]={status="gray_fallback",fallback_gray=true,reason=reason}
        log(bridge,"material_fallback_gray",role..": "..reason)
    end
    for _,role in ipairs({"core","accretion"})do
        local index=role=="core"and 0 or 1
        local candidate=palette[role];local cfg=options[role]or {}
        local old_ok,old=pcall(function()return component:GetMaterial(index)end)
        if old_ok then report.originals[index]={material=old} end
        if candidate.fallback_gray or not valid(bridge,candidate.source)then fallback(role,candidate.reason or "material no longer valid")
        else
            local vectors=selected_names(candidate.parameters.vectors,color_parameter,cfg.color_parameters,cfg.allow_unverified_parameters==true)
            local scalars=selected_names(candidate.parameters.scalars,emission_parameter,cfg.emissive_parameters,cfg.allow_unverified_parameters==true)
            local color=cfg.color or(role=="core"and {R=0,G=0,B=0,A=1}or {R=4,G=0.65,B=0.04,A=1})
            local intensity=cfg.intensity;if intensity==nil then intensity=role=="core"and 0 or 8 end
            local updates=0
            local dynamic
            local ok,message=pcall(function()
                if #vectors+#scalars>0 and type(env.FName)=="function"then
                    dynamic=component:CreateDynamicMaterialInstance(index,candidate.source,env.FName("None"))
                    if not valid(bridge,dynamic)then error("CreateDynamicMaterialInstance returned invalid object")end
                    if dynamic==candidate.source then error("refusing to edit source material instance")end
                    for _,name in ipairs(vectors)do dynamic:SetVectorParameterValue(env.FName(name),color);updates=updates+1 end
                    for _,name in ipairs(scalars)do dynamic:SetScalarParameterValue(env.FName(name),intensity);updates=updates+1 end
                    component:SetMaterial(index,dynamic)
                    report.dynamic_instances[#report.dynamic_instances+1]=dynamic
                else component:SetMaterial(index,candidate.source)end
            end)
            if not ok then
                -- Restore a partially assigned MID before falling back.
                if old_ok then pcall(function()component:SetMaterial(index,old)end)end
                fallback(role,tostring(message))
            else
                report[role]={status=updates>0 and "parameters_applied_unverified"or "named_asset_unverified",
                    path=candidate.path,selection=candidate.selection,parameter_updates=updates,
                    emissive_control=#scalars>0 and updates>0,visual_verified=false}
                log(bridge,"material_selected",role..": "..candidate.path.." (visual result unverified)")
            end
        end
    end
    local restored=false
    function report:restore()
        if restored then return true end
        if not valid(bridge,component)then restored=true;return true end
        local errors={}
        for index,entry in pairs(self.originals)do
            local ok,message=pcall(function()component:SetMaterial(index,entry.material)end)
            if not ok then errors[#errors+1]=tostring(message)end
        end
        if #errors>0 then return false,table.concat(errors,"; ")end
        self.dynamic_instances={};restored=true;return true
    end
    return report
end
return M

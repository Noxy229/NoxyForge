-- Copyright (c) 2026 Noxy229. SPDX-License-Identifier: MIT
local M = {}
local defaults = {
    max_sections=8, max_vertices=8192, max_triangles=16384,
    max_total_vertices=16384, max_total_triangles=32768,
    max_coordinate=100000, max_color=64,
}
local function finite(n)
    return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge
end
local function integer(n) return finite(n) and n%1==0 end
local function limits_for(overrides)
    if overrides~=nil and type(overrides)~="table" then return nil,"limits must be a table" end
    local out={}
    for name,default in pairs(defaults) do
        local value=overrides and overrides[name]
        if value==nil then value=default end
        if not finite(value) or value<=0 then return nil,"invalid limit: "..name end
        if name~="max_coordinate" and name~="max_color" and not integer(value) then
            return nil,"limit must be an integer: "..name
        end
        out[name]=value
    end
    return out
end
-- Do not rely on Lua's length operator for sparse or mixed-key input.
local function length(list, maximum, label)
    if type(list)~="table" then return nil,label.." must be an array" end
    local count,highest=0,0
    for key in pairs(list) do
        if not integer(key) or key<1 then return nil,label.." must have positive integer keys" end
        count=count+1
        if count>maximum or key>maximum then return nil,label.." exceeds its size limit" end
        highest=math.max(highest,key)
    end
    if highest~=count then return nil,label.." must be dense and 1-indexed" end
    return count
end
local function components(value,names,bound)
    if type(value)~="table" then return false end
    for _,key in ipairs(names) do
        if not finite(value[key]) or math.abs(value[key])>bound then return false end
    end
    return true
end
local function attributes(section,key,count,names,bound)
    if section[key]==nil then return true end
    local n,err=length(section[key],count,key)
    if not n then return false,err end
    if n~=0 and n~=count then return false,key.." length must match positions or be zero" end
    for i=1,n do
        if not components(section[key][i],names,bound) then return false,key.." contains invalid/non-finite components" end
    end
    return true
end
local function section_valid(section,lim)
    if type(section)~="table" then return false,"section must be a table" end
    local n,err=length(section.positions,lim.max_vertices,"positions")
    if not n then return false,err end
    if n<3 then return false,"at least three positions are required" end
    for i=1,n do
        if not components(section.positions[i],{"X","Y","Z"},lim.max_coordinate) then
            return false,"positions contain invalid/non-finite coordinates"
        end
    end
    local indices;indices,err=length(section.triangles,lim.max_triangles*3,"triangles")
    if not indices then return false,err end
    if indices<3 or indices%3~=0 then return false,"triangle index count must be a positive multiple of three" end
    for i=1,indices do
        local index=section.triangles[i]
        if not integer(index) or index<0 or index>=n then return false,"triangle index outside 0-based vertex range" end
    end
    for i=1,indices,3 do
        local a,b,c=section.triangles[i],section.triangles[i+1],section.triangles[i+2]
        if a==b or b==c or a==c then return false,"triangle repeats a vertex index" end
    end
    local ok;ok,err=attributes(section,"normals",n,{"X","Y","Z"},1)
    if not ok then return false,err end
    ok,err=attributes(section,"colors",n,{"R","G","B","A"},lim.max_color)
    if not ok then return false,err end
    for _,color in ipairs(section.colors or {}) do
        if color.A<0 or color.A>1 then return false,"color alpha must be between zero and one" end
    end
    for _,key in ipairs({"uv0","uv1","uv2","uv3"}) do
        ok,err=attributes(section,key,n,{"X","Y"},lim.max_coordinate)
        if not ok then return false,err end
    end
    return true,nil,n,indices/3
end
function M.validate(model,limits)
    if type(model)~="table" then return false,"mesh must be a table" end
    local lim,err=limits_for(limits)
    if not lim then return false,err end
    local sections=model.sections or {model}
    local count;count,err=length(sections,lim.max_sections,"sections")
    if not count then return false,err end
    if count==0 then return false,"at least one section is required" end
    local vertices,triangles=0,0
    for i=1,count do
        local ok,n,t;ok,err,n,t=section_valid(sections[i],lim)
        if not ok then return false,"section "..i..": "..err end
        vertices,triangles=vertices+n,triangles+t
        if vertices>lim.max_total_vertices or triangles>lim.max_total_triangles then
            return false,"mesh exceeds aggregate geometry limits"
        end
    end
    return true
end
local function section(name)
    return {name=name,positions={},normals={},colors={},uv0={},triangles={}}
end
local function vertex(s,x,y,z,nx,ny,nz,color,u,v)
    s.positions[#s.positions+1]={X=x,Y=y,Z=z}
    s.normals[#s.normals+1]={X=nx,Y=ny,Z=nz}
    s.colors[#s.colors+1]={R=color.R,G=color.G,B=color.B,A=color.A}
    s.uv0[#s.uv0+1]={X=u,Y=v}
end
local function triangle(s,a,b,c)
    local t=s.triangles;t[#t+1]=a;t[#t+1]=b;t[#t+1]=c
end
local function positive(options,key,default)
    local value=options[key]
    if value==nil then value=default end
    if not finite(value) or value<=0 then return nil,key.." must be positive and finite" end
    return value
end
local function segments(options,key,default,low,high)
    local value=options[key]
    if value==nil then value=default end
    if not integer(value) or value<low or value>high then return nil,key.." is outside tessellation limits" end
    return value
end
function M.black_hole(options)
    options=options or {}
    if type(options)~="table" then return nil,"options must be a table" end
    local lim,err=limits_for(options.limits);if not lim then return nil,err end
    local radius;radius,err=positive(options,"core_radius",60);if not radius then return nil,err end
    local inner;inner,err=positive(options,"inner_radius",radius*1.35);if not inner then return nil,err end
    local outer;outer,err=positive(options,"outer_radius",radius*3.5);if not outer then return nil,err end
    if inner<=radius or outer<=inner or outer>lim.max_coordinate then return nil,"radii must satisfy core < inner < outer within coordinate limit" end
    local ns;ns,err=segments(options,"sphere_segments",24,3,128);if not ns then return nil,err end
    local nl;nl,err=segments(options,"sphere_rings",8,2,64);if not nl then return nil,err end
    local nr;nr,err=segments(options,"ring_segments",48,3,256);if not nr then return nil,err end
    local nb;nb,err=segments(options,"ring_bands",3,1,16);if not nb then return nil,err end
    local thickness=options.ring_thickness
    if thickness==nil then thickness=0.4 end
    if not finite(thickness) or thickness<0 or thickness>radius then return nil,"invalid ring_thickness" end
    local sv,st=(ns+1)*(nl+1),2*ns*(nl-1)
    local rv,rt=2*(nr+1)*(nb+1),4*nr*nb
    if lim.max_sections<2 or math.max(sv,rv)>lim.max_vertices or math.max(st,rt)>lim.max_triangles
        or sv+rv>lim.max_total_vertices or st+rt>lim.max_total_triangles then
        return nil,"requested tessellation exceeds geometry limits"
    end
    local core=section("core")
    for latitude=0,nl do
        local theta=math.pi*latitude/nl
        for longitude=0,ns do
            local phi=2*math.pi*longitude/ns
            local x,y,z=math.sin(theta)*math.cos(phi),math.sin(theta)*math.sin(phi),math.cos(theta)
            vertex(core,radius*x,radius*y,radius*z,x,y,z,{R=0,G=0,B=0,A=1},longitude/ns,latitude/nl)
        end
    end
    for latitude=0,nl-1 do
        for longitude=0,ns-1 do
            local a=latitude*(ns+1)+longitude;local b=a+ns+1
            if latitude<nl-1 then triangle(core,a,b,b+1) end
            if latitude>0 then triangle(core,a,b+1,a+1) end
        end
    end
    local ring=section("accretion")
    for side=0,1 do
        local normal=side==0 and 1 or -1
        for band=0,nb do
            local t=band/nb;local r=inner+(outer-inner)*t
            for segment=0,nr do
                local phi=2*math.pi*segment/nr
                local arc=0.8+0.2*math.cos(phi)
                local color={R=(1+2*(1-t))*arc,G=(0.08+0.9*(1-t)^2)*arc,B=(0.01+0.25*(1-t)^4)*arc,A=1}
                vertex(ring,r*math.cos(phi),r*math.sin(phi),normal*thickness/2,0,0,normal,color,segment/nr,t)
            end
        end
        local base=side*(nb+1)*(nr+1)
        for band=0,nb-1 do
            for segment=0,nr-1 do
                local a=base+band*(nr+1)+segment;local b=a+nr+1
                if side==0 then triangle(ring,a,b,b+1);triangle(ring,a,b+1,a+1)
                else triangle(ring,a,b+1,b);triangle(ring,a,a+1,b+1) end
            end
        end
    end
    local model={name="black_hole",sections={core,ring},bounds_radius=outer}
    local ok;ok,err=M.validate(model,options.limits)
    if not ok then return nil,err end
    return model
end
return M

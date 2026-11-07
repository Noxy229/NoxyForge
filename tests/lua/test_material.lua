-- Copyright (c) 2026 Noxy229. SPDX-License-Identifier: MIT
local source=debug.getinfo(1,"S").source:gsub("^@","")
local prefix=source:match("^(.*)tests[/\\]lua[/\\]test_material%.lua$")
local root=arg[1]or(prefix and prefix~=""and prefix or ".")
package.path=root.."/src/ue4ss/Mods/shared/?.lua;"..package.path
local M=require("NoxyForge.material")
local passed,id=0,0
local function test(name,fn)
 local ok,err=pcall(fn);if not ok then io.stderr:write("FAIL "..name..": "..tostring(err).."\n");os.exit(1)end
 passed=passed+1;print("PASS "..name)
end
local function mat(path,vectors,scalars)
 id=id+1;local m={valid=true,id=id,path=path,VectorParameterValues={},ScalarParameterValues={}}
 function m:IsA(c)return c=="/Script/Engine.MaterialInterface"end
 function m:GetFullName()return "MaterialInstanceConstant "..self.path end
 for _,name in ipairs(vectors or {})do m.VectorParameterValues[#m.VectorParameterValues+1]={ParameterInfo={Name=name,Association=0}}end
 for _,name in ipairs(scalars or {})do m.ScalarParameterValues[#m.ScalarParameterValues+1]={ParameterInfo={Name=name,Association=0}}end
 function m:SetVectorParameterValue()error("source mutation")end
 function m:SetScalarParameterValue()error("source mutation")end
 return m
end
local function fixture(objects)
 local b={env={},logs={},enumerations=0}
 function b:valid(o)return type(o)=="table"and o.valid==true end
 function b:id(o)return o.id or tostring(o)end
 function b:find(path)return objects[path]end
 function b:log(code,message)self.logs[#self.logs+1]={code,message}end
 b.env.FName=function(s)return s end
 b.env.FindAllOf=function(class)b.enumerations=b.enumerations+1;local out={};for _,m in pairs(objects)do out[#out+1]=m end;return out end
 local gray=mat("/Engine/Default.Default");local c={valid=true,slots={[0]=gray,[1]=gray},created={}}
 function c:GetMaterial(i)return self.slots[i]end
 function c:SetMaterial(i,m)self.slots[i]=m end
 function c:CreateDynamicMaterialInstance(i,parent,name)
  assert(name=="None");local m=mat("/Engine/Transient.MID_"..i);m.vectors={};m.scalars={}
  function m:SetVectorParameterValue(k,v)self.vectors[k]=v end
  function m:SetScalarParameterValue(k,v)self.scalars[k]=v end
  self.created[#self.created+1]=m;self.slots[i]=m;return m
 end
 return b,c,gray
end
test("default fallback is explicit and never enumerates",function()
 local b,c,g=fixture({});local r=assert(M.apply(b,c));assert(b.enumerations==0)
 assert(r.used_default_material and r.core.fallback_gray and r.accretion.fallback_gray)
 assert(c.slots[0]==g and c.slots[1]==g)
end)
test("private MIDs configure both roles without source mutation",function()
 local a=mat("/Game/M_Dark.M_Dark",{"Base Color"},{"EmissiveStrength"})
 local z=mat("/Game/M_Glow.M_Glow",{"EmissiveColor"},{"EmissiveIntensity"})
 local b,c,g=fixture({[a.path]=a,[z.path]=z});local r=assert(M.apply(b,c,{core={path=a.path},accretion={path=z.path}}))
 assert(b.enumerations==0 and #c.created==2 and c.slots[0]~=a and c.slots[1]~=z)
 assert(c.slots[0].vectors["Base Color"].R==0 and c.slots[0].scalars.EmissiveStrength==0)
 assert(c.slots[1].vectors.EmissiveColor.R==4 and c.slots[1].scalars.EmissiveIntensity==8)
 assert(not r.core.visual_verified and r.accretion.emissive_control)
 assert(r:restore());assert(r:restore());assert(c.slots[0]==g and c.slots[1]==g)
end)
test("parent metadata excludes layers and terminates cycles",function()
 local a=mat("/Game/A.A",{"Color"});local p=mat("/Game/P.P",{"Tint"},{"GlowIntensity"});a.Parent=p;p.Parent=a
 a.VectorParameterValues[2]={ParameterInfo={Name="LayerColor",Association=1}}
 local b=fixture({});local r=M.parameters(b,a)
 assert(r.vectors.Color and r.vectors.Tint and r.scalars.GlowIntensity and not r.vectors.LayerColor and not r.complete)
end)
test("optional discovery caches once per caller world",function()
 local a=mat("/Game/M_Black.M_Black",{"Color"});local z=mat("/Game/M_Glow.M_Glow",{"Color"},{"GlowIntensity"})
 local b=fixture({[a.path]=a,[z.path]=z});local r=assert(M.resolve(b,{auto=true,cache_key="A"}))
 assert(r.core.source==a and r.accretion.source==z and b.enumerations==3)
 assert(M.resolve(b,{auto=true,cache_key="A"}));assert(b.enumerations==3)
 assert(M.resolve(b,{auto=true,cache_key="B"}));assert(b.enumerations==6)
 M.clear_cache(b);assert(M.resolve(b,{auto=true,cache_key="B"}));assert(b.enumerations==9)
end)
test("bounded scan excludes incompatible named materials",function()
 local a=mat("/Game/Decals/BlackGlow.BlackGlow",{"Color"},{"GlowIntensity"});local b=fixture({[a.path]=a})
 assert(#assert(M.enumerate(b,{max_candidates=1}))==1)
 local r=assert(M.resolve(b,{candidates=assert(M.enumerate(b))}));assert(r.core.fallback_gray and r.accretion.fallback_gray)
 assert(M.enumerate(b,{max_candidates=math.huge})==nil)
end)
test("non-material objects fail closed",function()
 local a=mat("/Game/Texture.Texture");function a:IsA()return false end
 local b,c=fixture({[a.path]=a});local r=assert(M.apply(b,c,{core={path=a.path}}));assert(r.core.fallback_gray and #c.created==0)
end)
test("failed setter restores the previous material",function()
 local a=mat("/Game/M_Black.M_Black",{"Color"});local b,c,g=fixture({[a.path]=a});local old=c.CreateDynamicMaterialInstance
 function c:CreateDynamicMaterialInstance(...)local mid=old(self,...);function mid:SetVectorParameterValue()error("missing setter")end;return mid end
 local r=assert(M.apply(b,c,{core={path=a.path}}));assert(r.core.fallback_gray and c.slots[0]==g)
end)
test("explicit unverified profile stays labelled unverified",function()
 local a=mat("/Engine/EmissiveMeshMaterial.EmissiveMeshMaterial");local b,c=fixture({[a.path]=a})
 local r=assert(M.apply(b,c,{accretion={path=a.path,color_parameters={"Color"},allow_unverified_parameters=true}}))
 assert(c.slots[1].vectors.Color.R==4 and r.accretion.visual_verified==false)
end)
test("invalid options allocate no dynamic instances",function()
 local b,c,g=fixture({});assert(M.apply(b,c,{core={path="https://example.com/m"}})==nil)
 assert(M.apply(b,c,{accretion={intensity=0/0}})==nil);assert(#c.created==0 and c.slots[0]==g)
end)
test("finite colors and intensity reject before native side effects",function()
 local a=mat("/Game/M_Glow.M_Glow",{"Color"});local b,c,g=fixture({[a.path]=a})
 for _,value in ipairs({math.huge,-math.huge,-1,65,"8",false})do
  assert(M.apply(b,c,{core={path=a.path,intensity=value}})==nil)
 end
 for _,value in ipairs({0/0,math.huge,-1,65,"4",false})do
  assert(M.apply(b,c,{accretion={path=a.path,color={R=value,G=1,B=1,A=1}}})==nil)
 end
 assert(M.apply(b,c,{accretion={color={R=1,G=1,B=1,A=2}}})==nil)
 assert(#c.created==0 and c.slots[0]==g and c.slots[1]==g)
end)
test("configured parameter names are dense and capped",function()
 local b,c=fixture({});local names={};for i=1,33 do names[i]="Color"end
 assert(M.apply(b,c,{core={color_parameters=names}})==nil)
 assert(M.apply(b,c,{core={emissive_parameters={[2]="GlowIntensity"}}})==nil)
 assert(M.apply(b,c,{core={color_parameters="Color"}})==nil)
 assert(M.apply(b,c,{core={color_parameters={string.rep("x",129)}}})==nil)
 assert(#c.created==0)
 names[33]=nil;assert(M.apply(b,c,{core={color_parameters=names}}))
end)
test("nil original material restores correctly",function()
 local a=mat("/Game/M_Black.M_Black",{"Color"});local b,c=fixture({[a.path]=a});c.slots[0]=nil
 local r=assert(M.apply(b,c,{core={path=a.path}}));assert(c.slots[0]~=nil);assert(r:restore());assert(c.slots[0]==nil)
end)
print(string.format("%d material tests passed",passed))

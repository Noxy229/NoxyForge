-- Copyright (c) 2026 Noxy229. SPDX-License-Identifier: MIT
local source=debug.getinfo(1,"S").source:gsub("^@","")
local inferred=source:match("^(.*)tests[/\\]lua[/\\]test_geometry%.lua$")
local root=arg[1] or (inferred and inferred~="" and inferred or ".")
package.path=root.."/src/ue4ss/Mods/shared/?.lua;"..package.path
local G=require("NoxyForge.geometry")
local Mesh=require("NoxyForge.mesh")
local passed=0
local function test(name,fn)
    local ok,err=pcall(fn)
    if not ok then io.stderr:write("FAIL "..name..": "..tostring(err).."\n");os.exit(1) end
    passed=passed+1;print("PASS "..name)
end
local function section()
    return {positions={{X=0,Y=0,Z=0},{X=1,Y=0,Z=0},{X=0,Y=1,Z=0}},triangles={0,1,2}}
end
local function rejected(mesh,limits)
    local ok,err=G.validate(mesh,limits)
    assert(ok==false and type(err)=="string" and #err>0)
end
local function winding(s)
    for i=1,#s.triangles,3 do
        local ai,bi,ci=s.triangles[i]+1,s.triangles[i+1]+1,s.triangles[i+2]+1
        local a,b,c=s.positions[ai],s.positions[bi],s.positions[ci]
        local ux,uy,uz=b.X-a.X,b.Y-a.Y,b.Z-a.Z
        local vx,vy,vz=c.X-a.X,c.Y-a.Y,c.Z-a.Z
        local nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
        local n=s.normals[ai]
        assert(nx*n.X+ny*n.Y+nz*n.Z>1e-8,"triangle winding disagrees with surface normal")
    end
end
test("minimal 0-based section accepts omitted attributes",function()assert(G.validate(section()))end)
test("black hole has bounded, nondegenerate outward-facing sections",function()
    local model,err=G.black_hole();assert(model,err);assert(G.validate(model));assert(#model.sections==2)
    local core,ring=model.sections[1],model.sections[2]
    assert(#core.positions==225 and #core.triangles==336*3)
    assert(#ring.positions==392 and #ring.triangles==576*3)
    winding(core);winding(ring)
    for _,s in ipairs(model.sections) do
        assert(#s.normals==#s.positions and #s.colors==#s.positions)
        for _,n in ipairs(s.normals) do assert(math.abs(n.X*n.X+n.Y*n.Y+n.Z*n.Z-1)<1e-10) end
    end
end)
test("sphere radius and annulus gap obey authored dimensions",function()
    local model=assert(G.black_hole({core_radius=10,inner_radius=15,outer_radius=25}))
    for _,v in ipairs(model.sections[1].positions) do assert(math.abs(math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z)-10)<1e-10) end
    for _,v in ipairs(model.sections[2].positions) do
        local r=math.sqrt(v.X*v.X+v.Y*v.Y);assert(r>=15-1e-10 and r<=25+1e-10)
    end
end)
test("generation rejects invalid radii and excessive tessellation before allocation",function()
    assert(G.black_hole({core_radius=0})==nil)
    assert(G.black_hole({core_radius=20,inner_radius=10})==nil)
    assert(G.black_hole({ring_segments=1000000000})==nil)
    assert(G.black_hole({sphere_segments=128,sphere_rings=64})==nil)
    assert(G.black_hole({ring_thickness=0/0})==nil)
    assert(G.black_hole({limits={max_total_vertices=10}})==nil)
end)
test("NaN, infinity, invalid indices and repeated vertices are rejected",function()
    for _,value in ipairs({0/0,math.huge,-math.huge}) do
        local s=section();s.positions[1].X=value;rejected(s)
        s=section();s.triangles[1]=value;rejected(s)
    end
    for _,index in ipairs({-1,3,0.5}) do local s=section();s.triangles[1]=index;rejected(s) end
    local s=section();s.triangles={0,1,1};rejected(s)
end)
test("sparse and mixed-key arrays cannot pass Lua length ambiguity",function()
    local s=section();s.positions[2]=nil;rejected(s)
    s=section();s.triangles.extra=4;rejected(s)
    s=section();s.triangles={[1]=0,[2]=1,[4]=2};rejected(s)
end)
test("attribute dimensions and bounds are checked",function()
    local s=section();s.normals={{X=0,Y=0,Z=1}};rejected(s)
    s=section();s.colors={{R=0,G=0,B=0,A=1},{R=0,G=0,B=0,A=1},{R=0,G=0,B=0,A=2}};rejected(s)
    s=section();s.uv0={{X=0,Y=0},{X=1,Y=0},{X=0,Y=math.huge}};rejected(s)
    s=section();s.positions[1].X=101;rejected(s,{max_coordinate=100})
    rejected({sections={section(),section()}},{max_total_vertices=5})
    rejected(section(),{max_vertices=-1})
end)
test("HDR colors are valid within configured bounds",function()
    local s=section();s.colors={{R=2,G=0,B=0,A=1},{R=2,G=1,B=0,A=1},{R=2,G=1,B=0,A=1}}
    assert(G.validate(s));rejected(s,{max_color=1})
end)
local function engine(fail_upload)
    local state={spawns=0,actor_destroyed=0,component_destroyed=0,sections={}}
    local component={valid=true}
    function component:SetMobility(value)assert(value==2)end
    function component:SetCollisionEnabled(value)assert(value==0)end
    function component:CreateMeshSection_LinearColor(...)
        assert(select('#',...)==12,"wrong UFunction arity")
        local args={...};assert(args[11]==false and args[12]==false)
        if fail_upload then error("upload failed") end
        state.sections[#state.sections+1]=args[1]
    end
    function component:SetMaterial(index,material)assert(material.valid)end
    local actor={valid=true}
    function actor:AddComponentByClass(class,manual,transform,deferred)
        assert(class.valid and manual==false and deferred==false)
        assert(transform.Rotation.W==1 and transform.Scale3D.X==1)
        return component
    end
    function actor:K2_GetRootComponent()return component end
    function actor:SetActorEnableCollision(value)assert(value==false)end
    function actor:K2_SetActorLocation(position,sweep,hit,teleport)assert(not sweep and teleport);return true end
    function actor:K2_SetActorRotation(rotation,teleport)assert(teleport);return true end
    function actor:SetActorScale3D(scale)assert(scale.X>0)end
    function component:K2_DestroyComponent(owner)
        assert(owner==actor);state.component_destroyed=state.component_destroyed+1;self.valid=false
    end
    local world={valid=true}
    function world:SpawnActor(class,location,rotation)state.spawns=state.spawns+1;return actor end
    local bridge={}
    function bridge:valid(o)return type(o)=="table" and o.valid==true end
    function bridge:find(path)return {valid=true,path=path} end
    function bridge:destroy(o)assert(o==actor);state.actor_destroyed=state.actor_destroyed+1;o.valid=false end
    return bridge,{world=world},state
end
test("mesh service uses native arrays and owns idempotent cleanup",function()
    local b,c,s=engine();local handle,err=Mesh.spawn(b,c,assert(G.black_hole()),{location={X=1,Y=2,Z=3}})
    assert(handle,err);assert(s.spawns==1 and #s.sections==2 and s.sections[1]==0 and s.sections[2]==1)
    assert(handle.uses_default_material)
    assert(handle:destroy());assert(handle:destroy());assert(s.actor_destroyed==1 and s.component_destroyed==1)
end)
test("partial mesh upload failure destroys both acquired resources",function()
    local b,c,s=engine(true);local handle,err=Mesh.spawn(b,c,section())
    assert(handle==nil and err:find("upload failed",1,true));assert(s.actor_destroyed==1 and s.component_destroyed==1)
end)
test("invalid geometry and remote material paths allocate no engine objects",function()
    local b,c,s=engine();local invalid=section();invalid.triangles={0,1,4}
    assert(Mesh.spawn(b,c,invalid)==nil);assert(s.spawns==0)
    assert(Mesh.spawn(b,c,section(),{material_path="https://example.com/material"})==nil);assert(s.spawns==0)
end)
print(string.format("%d geometry/mesh tests passed",passed))

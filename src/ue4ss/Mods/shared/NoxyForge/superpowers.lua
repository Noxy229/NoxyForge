local mathx=require("NoxyForge.mathx")
local Geometry=require("NoxyForge.geometry")
local Mesh=require("NoxyForge.mesh")
local Material=require("NoxyForge.material")
local P={id="superpowers"}
function P:initialize(app)
    self.snapshots={};self.weapon_snapshots={};self.hole=nil;self.actors={};self.refresh=0
    if app.config.keybinds then
        app:key("F5",function(runtime)
            runtime.config.blade_multiplier=runtime.config.blade_multiplier==1 and 10 or 1
            self:restore_weapons(runtime)
            runtime.bridge:log("blade_multiplier",tostring(runtime.config.blade_multiplier))
        end)
        app:key("F6",function(runtime)
            runtime.config.protection=not runtime.config.protection
            runtime.config.strength=runtime.config.protection
            self:restore_fields(runtime)
            runtime.bridge:log("protection",tostring(runtime.config.protection))
        end)
        app:key("F7",function(runtime,context) self:toggle_hole(runtime,context) end)
        app:key("F8",function(runtime,context)
            runtime.bridge:log("diagnostics","player="..context.player_id.." world="..context.world_id.." owned="..#runtime.life.cleanups)
            for _,property in ipairs({"Invulnerable","Block Spine Breaking","Max Angular Force","All Body Tonus"}) do
                local value=runtime.bridge:get(context.pawn,property)
                runtime.bridge:log("property",property.."="..tostring(value))
            end
            for _,record in pairs(self.weapon_snapshots) do
                for property,baseline in pairs(record.values) do
                    local value=runtime.bridge:get(record.object,property)
                    runtime.bridge:log("weapon_property",property..": baseline="..baseline.." current="..tostring(value))
                end
            end
        end)
        app:key("F9",function(runtime) runtime.config.standing=not runtime.config.standing;self:restore_fields(runtime) end)
    end
end
function P:restore_fields(app)
    for _,record in pairs(self.snapshots) do
        if app.bridge:valid(record.object) then
            for property,value in pairs(record.values) do app.bridge:set(record.object,property,value) end
        end
    end
    self.snapshots={}
end
function P:apply_fields(app,object,values)
    local key=app.bridge:id(object)
    local record=self.snapshots[key]
    if not record then record={object=object,values={}};self.snapshots[key]=record end
    for property,value in pairs(values) do
        if record.values[property]==nil then
            local old=app.bridge:get(object,property)
            if old~=nil then record.values[property]=old end
        end
        if record.values[property]~=nil then
            local ok,err=app.bridge:set(object,property,value)
            if not ok then error(err) end
        end
    end
end
local function finite(value)
    return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end
function P:restore_weapon(app,record)
    if app.bridge:valid(record.object) then
        for property,value in pairs(record.values) do
            local ok,err=app.bridge:set(record.object,property,value)
            if not ok then app.bridge:log("weapon_restore_error",tostring(err)) end
        end
    end
end
function P:restore_weapons(app)
    for _,record in pairs(self.weapon_snapshots) do self:restore_weapon(app,record) end
    self.weapon_snapshots={}
end
function P:apply_weapons(app,context,dt)
    local multiplier=app.config.blade_multiplier
    if not finite(multiplier) or multiplier<1 or multiplier>20 then
        self:restore_weapons(app);return
    end
    local held={}
    local properties=app.profile.properties or {}
    for _,property in ipairs({properties.right_weapon or "Weapon R",properties.left_weapon or "Weapon L"}) do
        local weapon=app.bridge:get(context.pawn,property)
        if app.bridge:valid(weapon) then
            local id=app.bridge:id(weapon)
            if id then held[id]=weapon end
        end
    end
    -- Release first, including a dropped weapon when no replacement is held.
    for id,record in pairs(self.weapon_snapshots) do
        if not held[id] or held[id]~=record.object then
            self:restore_weapon(app,record);self.weapon_snapshots[id]=nil
        end
    end
    if multiplier==1 then self:restore_weapons(app);return end
    local fields=app.profile.weapon_sharpness or {"Edge Sharpness","Tip Sharpness"}
    for id,weapon in pairs(held) do
        local record=self.weapon_snapshots[id]
        if not record then record={object=weapon,values={},held_seconds=0};self.weapon_snapshots[id]=record end
        -- Spawned weapons receive reflected sharpness after their first ticks.
        -- Keep hands off until initialization has had time to settle.
        local elapsed=finite(dt) and math.max(0,math.min(dt,.25)) or 0
        record.held_seconds=math.min(.75,record.held_seconds+elapsed)
        if record.held_seconds>=.75 then
            for _,property in ipairs(fields) do
                local current=app.bridge:get(weapon,property)
                if finite(current) and current>=0 then
                    if record.values[property]==nil then record.values[property]=current end
                    local baseline=record.values[property]
                    -- Baselines are immutable, so updates cannot compound the multiplier.
                    local value=baseline==0 and 0 or math.min(10000,baseline*multiplier)
                    if finite(value) then
                        local ok,err=app.bridge:set(weapon,property,value)
                        if not ok then error(err) end
                    end
                end
            end
        end
    end
end
function P:toggle_hole(app,context)
    if self.hole then app.life:cleanup(self.id,"toggle_off");return end
    if #app.life.cleanups>=app.config.max_owned_actors then error("effect limit reached") end
    local position=app.bridge:location(context.pawn)
    local forward=context.pawn:GetActorForwardVector()
    local centre={X=position.X+forward.X*300,Y=position.Y+forward.Y*300,Z=position.Z+120}
    local options=app.config.black_hole
    local model,err=Geometry.black_hole()
    if not model then error(err) end
    local ring_path="/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial"
    local ring=app.bridge:find(ring_path)
    local materials=app.bridge:valid(ring) and {accretion=ring_path} or nil
    local handle;handle,err=Mesh.spawn(app.bridge,context,model,{location=centre,rotation={Pitch=20,Yaw=0,Roll=0},scale=options.size,materials=materials})
    if not handle then error(err) end
    Material.apply(app.bridge,handle.component,{
        accretion={path=ring_path,color_parameters={"Color","EmissiveColor","Emissive Color"},
            color={R=2,G=0.32,B=0.02,A=1},allow_unverified_parameters=true}
    })
    local actor=handle.actor
    self.hole={actor=actor,handle=handle,centre=centre,age=0,options=options}
    local key=app.bridge:id(actor)
    local ok,message=app:own(self.id,key,function(reason)
        local removed,remove_error=handle:destroy()
        self.hole=nil
        if not removed then error(remove_error) end
        app.bridge:log("effect_removed",tostring(reason))
    end)
    if not ok then handle:destroy();self.hole=nil;error(message) end
    app.bridge:log("effect_spawned","Native procedural mesh; bounded attraction active. Material prototype; emissive ring="..tostring(materials~=nil))
end
function P:world_changed(app)
    self:restore_fields(app);self:restore_weapons(app);self.hole=nil;self.actors={};self.refresh=0
end
function P:update(app,context,dt)
    self:apply_weapons(app,context,dt)
    if app.config.protection then self:apply_fields(app,context.pawn,app.profile.protection) end
    if app.config.strength then self:apply_fields(app,context.pawn,app.profile.strength) end
    if app.config.standing then self:apply_fields(app,context.pawn,app.profile.standing) end
    if not self.hole then return end
    if not app.bridge:valid(self.hole.actor) then self.hole=nil;return end
    self.hole.age=self.hole.age+dt
    if self.hole.age>=self.hole.options.duration then app.life:cleanup(self.id,"expired");return end
    self.refresh=self.refresh-dt
    if self.refresh<=0 then self.actors=app.bridge:actors(app.profile,context,app.config.max_targets);self.refresh=.25 end
    for _,actor in ipairs(self.actors) do
        if app.bridge:valid(actor) and app.bridge:id(actor)~=context.player_id then
            local v,err=mathx.attraction(app.bridge:location(actor),self.hole.centre,self.hole.options)
            if not v then error(err) end
            app.bridge:impulse(actor,{X=v.X*dt,Y=v.Y*dt,Z=v.Z*dt})
        end
    end
end
function P:player_changed(app) self:world_changed(app) end
function P:shutdown(app) self:restore_fields(app);self:restore_weapons(app) end
return P

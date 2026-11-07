local Bridge={};Bridge.__index=Bridge
function Bridge.new(environment)
    local env=environment or _G
    return setmetatable({env=env,helpers=require("UEHelpers")},Bridge)
end
function Bridge:log(code,message)
    print(string.format("[NoxyForge][%s] %s\n",code,tostring(message)))
end
function Bridge:valid(object)
    if object==nil then return false end
    local ok,value=pcall(function() return object:IsValid() end)
    return ok and value==true
end
function Bridge:id(object)
    if not self:valid(object) then return nil end
    return tostring(object:GetAddress())
end
function Bridge:get(object,property)
    if not self:valid(object) then return nil,"invalid object" end
    local ok,value=pcall(function() return object[property] end)
    if not ok or value==nil then return nil,"missing property: "..property end
    return value
end
function Bridge:set(object,property,value)
    if not self:valid(object) then return nil,"invalid object" end
    local old,err=self:get(object,property)
    if old==nil then return nil,err end
    if type(old)~=type(value) then return nil,"property type mismatch: "..property end
    local ok,message=pcall(function() object[property]=value end)
    if not ok then return nil,tostring(message) end
    return true
end
function Bridge:context()
    local world=self.helpers.GetWorld()
    local pc=self.helpers.GetPlayerController()
    if not self:valid(world) or not self:valid(pc) then return nil end
    local pawn=pc.Pawn
    local statics=self.helpers.GetGameplayStatics()
    self.now=statics:GetRealTimeSeconds(world)
    return {world=world,world_id=self:id(world),pawn=pawn,player_id=self:id(pawn),controller=pc,paused=statics:IsGamePaused(world)}
end
function Bridge:defer(callback) self.env.ExecuteInGameThread(callback) end
function Bridge:loop(interval,callback)
    if not self.env.LoopInGameThreadWithDelay or not self.env.CancelDelayedAction then
        error("Pinned UE4SS delayed-action API is required")
    end
    local handle
    handle=self.env.LoopInGameThreadWithDelay(interval,function()
        if callback()==true and handle then self.env.CancelDelayedAction(handle);handle=nil end
    end)
    return function() if handle then self.env.CancelDelayedAction(handle);handle=nil end end
end
function Bridge:key(key,callback) self.env.RegisterKeyBind(self.env.Key[key],callback) end
function Bridge:find(path)
    local object=self.env.StaticFindObject(path)
    if self:valid(object) then return object end
    if self.env.LoadAsset then
        local ok,value=pcall(self.env.LoadAsset,path)
        if ok and self:valid(value) then return value end
    end
    return nil,"asset unavailable: "..path
end
function Bridge:actors(profile,context,limit)
    local candidates=self.env.FindAllOf(profile.character_short_name) or {};local actors={}
    for _,actor in ipairs(candidates) do
        if #actors>=limit then break end
        if self:valid(actor) and self:id(actor)~=context.player_id then
            local ok,same=pcall(function() return self:id(actor:GetWorld())==context.world_id end)
            if ok and same then actors[#actors+1]=actor end
        end
    end
    return actors
end
function Bridge:location(actor)
    local value=actor:K2_GetActorLocation()
    return {X=value.X,Y=value.Y,Z=value.Z}
end
function Bridge:spawn_sphere(context,location,size,asset_path)
    local cls,err=self:find("/Script/Engine.StaticMeshActor")
    if not cls then return nil,err end
    local mesh;mesh,err=self:find(asset_path)
    if not mesh then return nil,err end
    -- This is UE4SS's documented UWorld wrapper, not a raw function pointer.
    local actor=context.world:SpawnActor(cls,location,{Pitch=0,Yaw=0,Roll=0})
    if not self:valid(actor) then return nil,"SpawnActor returned no valid actor" end
    local ok,message=pcall(function()
        local component=actor.StaticMeshComponent
        if not self:valid(component) then error("missing StaticMeshComponent") end
        component:SetMobility(2)
        actor:SetActorEnableCollision(false)
        if not component:SetStaticMesh(mesh) then error("SetStaticMesh rejected asset") end
        actor:SetActorScale3D({X=size,Y=size,Z=size})
    end)
    if not ok then self:destroy(actor);return nil,tostring(message) end
    return actor
end
function Bridge:destroy(actor)
    if self:valid(actor) then actor:K2_DestroyActor() end
end
function Bridge:impulse(actor,vector)
    local mesh,err=self:get(actor,"Mesh")
    if not mesh or not self:valid(mesh) then return nil,err or "missing mesh" end
    mesh:AddImpulse(vector,self.env.FName("pelvis"),true)
    return true
end
function Bridge:clock() return self.now or 0 end
return Bridge

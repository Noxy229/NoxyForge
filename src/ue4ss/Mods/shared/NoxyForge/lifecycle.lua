local Lifecycle={};Lifecycle.__index=Lifecycle
function Lifecycle.new(log)
    return setmetatable({epoch=0,world=nil,state="waiting",listeners={},cleanups={},log=log or function()end},Lifecycle)
end
function Lifecycle:on(event,callback)
    assert(type(callback)=="function","event callback required")
    local item={callback=callback,active=true}
    self.listeners[event]=self.listeners[event] or {};table.insert(self.listeners[event],item)
    return function() item.active=false end
end
function Lifecycle:emit(event,payload)
    local listeners=self.listeners[event] or {};local snapshot={}
    for _,item in ipairs(listeners) do snapshot[#snapshot+1]=item end
    for _,item in ipairs(snapshot) do
        if item.active then local ok,err=pcall(item.callback,payload);if not ok then self.log("event_error",tostring(err)) end end
    end
end
function Lifecycle:own(owner,key,cleanup)
    assert(type(owner)=="string" and type(cleanup)=="function","ownership requires owner and cleanup")
    if #self.cleanups>=256 then return nil,"ownership limit reached" end
    for _,entry in ipairs(self.cleanups) do
        if entry.owner==owner and entry.key==key then return nil,"resource already owned" end
    end
    self.cleanups[#self.cleanups+1]={owner=owner,key=key,cleanup=cleanup}
    return true
end
function Lifecycle:cleanup(owner,reason)
    local keep,run={},{}
    for _,entry in ipairs(self.cleanups) do
        if not owner or entry.owner==owner then run[#run+1]=entry else keep[#keep+1]=entry end
    end
    -- Detach first: reentrant cleanup cannot execute an entry twice.
    self.cleanups=keep
    local errors={}
    for i=#run,1,-1 do
        local ok,err=pcall(run[i].cleanup,reason)
        if not ok then errors[#errors+1]=tostring(err);self.log("cleanup_error",tostring(err)) end
    end
    return errors
end
function Lifecycle:transition(world)
    if self.state=="stopped" then return false end
    if world==self.world then return false end
    self.epoch=self.epoch+1
    self:cleanup(nil,"world_changed")
    local previous=self.world;self.world=world;self.state=world and "running" or "waiting"
    self:emit("world_changed",{world=world,previous=previous,epoch=self.epoch})
    return true
end
function Lifecycle:guard(callback)
    local epoch=self.epoch
    return function(...)
        if self.state~="running" or epoch~=self.epoch then return nil,"stale world callback" end
        return callback(...)
    end
end
function Lifecycle:stop()
    if self.state=="stopped" then return end
    self.epoch=self.epoch+1;self.state="stopped"
    self:cleanup(nil,"shutdown");self:emit("stopped",{})
end
return Lifecycle

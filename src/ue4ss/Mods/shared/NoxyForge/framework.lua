local Lifecycle=require("NoxyForge.lifecycle")
local Bridge=require("NoxyForge.ue4ss")
local Settings=require("NoxyForge.settings")
local Profiles=require("NoxyForge.profiles")
local Framework={};Framework.__index=Framework
Framework.VERSION="0.1.0-alpha.1"
Framework.register_profile=Profiles.register
function Framework.new(config,bridge)
    local valid,err=Settings.validate(config);assert(valid,err)
    local self=setmetatable({config=config,bridge=bridge or Bridge.new(),plugins={},started=false,stopping=false,
        pending=false,context=nil,last_clock=nil,commands={},keys={}},Framework)
    self.profile=Profiles.get(config.profile)
    assert(self.profile,"unregistered game profile: "..config.profile)
    self.life=Lifecycle.new(function(code,message) self.bridge:log(code,message) end)
    return self
end
function Framework:register(plugin)
    assert(not self.started,"register plugins before start")
    assert(type(plugin.id)=="string" and not self.plugins[plugin.id],"duplicate or invalid plugin id")
    self.plugins[plugin.id]={module=plugin,enabled=true}
end
function Framework:queue(callback)
    if self.stopping or self.life.state=="stopped" then return nil,"framework stopped" end
    if #self.commands>=32 then return nil,"command queue full" end
    self.commands[#self.commands+1]={epoch=self.life.epoch,callback=callback}
    return true
end
function Framework:key(key,callback)
    if self.keys[key] then return nil,"duplicate keybind" end
    self.keys[key]=true
    local owner=self.invoking_plugin
    self.bridge:key(key,function()
        if not self.started or self.stopping then return end
        if owner and (not self.plugins[owner] or not self.plugins[owner].enabled) then return end
        self:queue(function(...)
            if owner and (not self.plugins[owner] or not self.plugins[owner].enabled) then return end
            return callback(...)
        end)
    end)
    return true
end
function Framework:own(owner,key,cleanup) return self.life:own(owner,key,cleanup) end
function Framework:fault(id,message,failed_hook)
    local plugin=self.plugins[id]
    if not plugin or plugin.faulted then return end
    plugin.enabled=false;plugin.faulted=true
    -- A failed update may already have modified reversible player fields.
    -- Restore those before disposing resources, without recursively retrying a
    -- shutdown hook that itself caused the failure.
    if failed_hook~="shutdown" and plugin.module.shutdown then
        local previous=self.invoking_plugin;self.invoking_plugin=id
        local ok,err=pcall(plugin.module.shutdown,plugin.module,self)
        self.invoking_plugin=previous
        if not ok then self.bridge:log("shutdown_error",id..": "..tostring(err)) end
    end
    self.life:cleanup(id,"plugin_error")
    self.bridge:log("plugin_error",id..": "..tostring(message))
end
function Framework:invoke(name,...)
    for id,plugin in pairs(self.plugins) do
        -- Older plugins already restore their actor references on world_changed.
        -- Reuse that path when a new pawn appears in the existing world.
        local callback=plugin.module[name]
        if name=="player_changed" and not callback then callback=plugin.module.world_changed end
        if plugin.enabled and callback then
            local previous=self.invoking_plugin;self.invoking_plugin=id
            local ok,message=pcall(callback,plugin.module,self,...)
            self.invoking_plugin=previous
            if not ok then self:fault(id,message,name) end
        end
    end
end
function Framework:tick()
    if self.stopping or not self.started then return end
    local context=self.bridge:context()
    local world=context and context.world_id or nil
    local previous=self.context
    local changed=self.life:transition(world)
    local player=context and context.player_id or nil
    local old_player=previous and previous.player_id or nil
    local player_changed=not changed and player~=old_player
    if player_changed then
        self.life.epoch=self.life.epoch+1
        self.life:cleanup(nil,"player_changed")
    end
    self.context=context
    if changed or player_changed then self.commands={};self.last_clock=nil end
    if changed then self:invoke("world_changed",context) end
    if player_changed then
        self.life:emit("player_changed",{player=player,previous=old_player,epoch=self.life.epoch})
        self:invoke("player_changed",context,previous)
    end
    local clock=self.bridge:clock()
    local dt=self.last_clock and math.max(0,math.min(.1,clock-self.last_clock)) or self.config.interval_ms/1000
    self.last_clock=clock
    if not context or not self.profile.accepts(self.bridge,context.pawn) then return end
    local commands=self.commands;self.commands={}
    for _,item in ipairs(commands) do
        if self.stopping then break end
        if item.epoch==self.life.epoch then
            local ok,err=pcall(item.callback,self,context)
            if not ok then self.bridge:log("command_error",tostring(err)) end
        end
    end
    if self.stopping then return end
    if not context.paused then self:invoke("update",context,dt) end
end
function Framework:start()
    if self.started then return nil,"framework already started" end
    self.started=true
    if self.config.keybinds then
        self.keys.F10=true
        self.bridge:key("F10",function()
            if not self.started or self.stopping then return end
            self.bridge:defer(function()
                if self.started and not self.stopping then self:stop() end
            end)
        end)
    end
    self:invoke("initialize")
    self.bridge:log("ready","NoxyForge "..self.VERSION.."; profile="..self.profile.id)
    self.cancel_loop=self.bridge:loop(self.config.interval_ms,function()
        if self.stopping or not self.started then return true end
        local ok,message=pcall(self.tick,self)
        if not ok then self.bridge:log("tick_error",tostring(message)) end
        return false
    end)
    return true
end
function Framework:stop()
    if self.stopping then return end
    self.stopping=true;self.commands={}
    if self.cancel_loop then self.cancel_loop();self.cancel_loop=nil end
    self.bridge:defer(function()
        self:invoke("shutdown")
        self.life:stop();self.started=false
        self.bridge:log("stopped","owned effects removed and reversible fields restored")
    end)
end
return Framework

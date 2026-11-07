local Profiles={}
local registry={half_sword=require("NoxyForge.half_sword")}
function Profiles.register(profile)
    if type(profile)~="table" or type(profile.id)~="string" or not profile.id:match("^[%w_]+$") or type(profile.accepts)~="function" then
        return nil,"invalid game profile"
    end
    if registry[profile.id] then return nil,"game profile already registered" end
    registry[profile.id]=profile;return true
end
function Profiles.get(id) return registry[id] end
return Profiles

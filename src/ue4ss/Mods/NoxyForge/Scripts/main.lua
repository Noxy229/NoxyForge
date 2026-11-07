local Framework=require("NoxyForge.framework")
local config=require("NoxyForge.config")
local app=Framework.new(config)
for _,module in ipairs(config.plugins) do app:register(require(module)) end
app:start()
-- UE4SS unloads its own keybinds. Explicit F10 cleanup is recommended before hot reload.
ModRef.OnUnload=function() app:stop() end

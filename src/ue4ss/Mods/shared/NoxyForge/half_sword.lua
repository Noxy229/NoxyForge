local P={id="half_sword",name="Half Sword",steam_app_id=2397300,builds={ [24185754]=true },
    character_class="/Game/Character/Blueprints/Willie_BP.Willie_BP_C",
    character_short_name="Willie_BP_C",weapon_class="/Game/Assets/Weapons/Blueprints/ModularWeaponBP.ModularWeaponBP_C"}
P.protection={Invulnerable=true,["Block Spine Breaking"]=true,["Force Disable Dismemberment"]=true}
-- Deliberately bounded presets; no promise of a globally multiplied damage value.
P.strength={["Max Angular Force"]=15000,["R Grab Force Limit"]=2500000,["L Grab Force Limit"]=2500000}
P.standing={["All Body Tonus"]=100,["Upper Body Tonus"]=1,["Leg R Tonus"]=1,["Leg L Tonus"]=1,
    ["Head Tonus"]=1,["Force Fall"]=false,["Bend Over Extreme"]=false,["Block Body Muscles"]=false,
    ["Block Upper Leg Muscles"]=false,["Block Lower Leg Muscles"]=false}
P.weapon_sharpness={"Edge Sharpness","Tip Sharpness"}
P.properties={mesh="Mesh",right_weapon="Weapon R",left_weapon="Weapon L"}
P.assets={sphere="/Engine/BasicShapes/Sphere.Sphere",default_material="/Engine/EngineMaterials/DefaultMaterial.DefaultMaterial"}
function P.accepts(bridge,pawn)
    if not bridge:valid(pawn) then return false end
    local ok,value=pcall(function() return pawn:GetClass():GetFName():ToString() end)
    return ok and value==P.character_short_name
end
return P

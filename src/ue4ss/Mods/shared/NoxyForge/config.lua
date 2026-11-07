return {
    schema_version=1,
    profile="half_sword",
    interval_ms=50,
    max_targets=16,
    max_owned_actors=8,
    -- Nothing is altered until a feature is explicitly enabled.
    protection=false,
    strength=false,
    standing=false,
    blade_multiplier=1,
    black_hole={radius=700,acceleration=350,softness=120,swirl=100,duration=10,size=1.2},
    keybinds=true,
    plugins={"NoxyForge.superpowers"},
}

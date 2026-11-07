# NoxyForge

A profile-driven UE4SS mod framework by **Noxy229**, starting with Half Sword.

NoxyForge provides a managed game-thread loop, world-change lifecycle,
plugin isolation, reversible property presets and owned-effect cleanup.
The included Half Sword Superpowers plugin is the first client of this API.

**Status: experimental alpha.** This is an Unreal/UE4SS framework. Unity is not
supported. Only the Half Sword profile has a declared compatibility target.

## What runs where

- The framework and plugins run through UE4SS inside Unreal's game context.
- Spawned effects are ordinary engine actors/components, not desktop overlays.
- There is no bespoke process injector, fixed process ID or raw memory offset API.
- The initial gravity effect uses authored procedural sphere/annulus geometry and
  a bounded force model. Its materials are a prototype. A realistic lens shader is a
  separate graphics feature; a sphere alone is not a photorealistic black hole.

See [the validation report](docs/validation.md) for exactly which paths have been
verified. Source-level tests do not count as proof that an effect works in-game.

## Target

| Item | Target |
|---|---|
| Game | Half Sword Early Access 0.6.1.5 |
| Steam app | 2397300 |
| Steam build | 24185754 |
| Dependency | Pinned UE4SS experimental artifact in `ue4ss.lock.json` |
| Runtime | UE4SS Lua API; game-thread delayed actions |
| Tooling | Python 3.11+, Lua 5.4+ for tests |

Other game builds must be validated before being added to the compatibility list.

## Installation

Installation and removal are handled by [the deployment tool](docs/installation.md).
The tool verifies the dependency SHA-256, backs up overwritten files, and refuses
to change an installation while the game is running.

Typical source checkout workflow:

```sh
python tools/forge.py --help
python tools/forge.py doctor --game-root "/path/to/Half Sword"
```

Obtain the exact dependency artifact listed in `ue4ss.lock.json` from the
[UE4SS releases](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest).
The tag can move; the pinned filename and digest are authoritative.

For Proton, the documented proxy-loading launch option is normally:

```text
WINEDLLOVERRIDES="dwmapi=n,b" %command%
```

Keep any existing launch options when configuring the game. Do not mix independent
proxy loaders without checking their own compatibility instructions.

## Controls

Features are off by default. Keys work while the game has focus.

| Key | Action |
|---|---|
| F5 | Toggle held weapon sharpness parameters between 1× and 10× |
| F6 | Toggle the profile's protection and strength presets |
| F7 | Spawn/remove the native gravity-effect prototype |
| F8 | Write context diagnostics to the UE4SS log |
| F9 | Toggle experimental standing support |
| F10 | Stop NoxyForge, remove owned effects and restore recorded values |

Settings live in `Mods/shared/NoxyForge/config.lua`. Restart the mod after editing.
Use F10 before hot reload so native effects can be cleaned up on the game thread.
A map change also invalidates queued commands and cleans up owned effects.

Property presets are game-specific. Increased motor settings are not a guarantee
of multiplied punch damage, invincibility against every game rule, or disabled
ragdoll physics.

## Write a plugin

Plugins are modules loaded by the single NoxyForge entry mod. Shared module files
do **not** create a shared Lua singleton between unrelated UE4SS mod states.

```lua
return {
    id = "my_feature",
    initialize = function(self, forge)
        forge:key("F4", function(runtime, context)
            runtime.bridge:log("example", "Active player: " .. context.player_id)
        end)
    end,
    update = function(self, forge, context, dt)
        -- Already on the managed game-thread loop.
    end,
    shutdown = function(self, forge)
        -- Restore your reversible state here.
    end,
}
```

Add the module name to `config.plugins`. See [API and lifecycle](docs/api.md).

## Development

```sh
lua tests/lua/run.lua .
lua tests/lua/test_geometry.lua .
lua tests/lua/test_superpowers.lua .
lua tests/lua/test_material.lua .
python -m unittest discover -s tests/python -v
```

The project has no third-party Python runtime dependencies. UE4SS itself is a
separate native dependency and must be initialized successfully before gameplay
features can be tested.

## References

- [UE4SS documentation](https://docs.ue4ss.com/)
- [Pinned UE4SS source](https://github.com/UE4SS-RE/RE-UE4SS/tree/4fb9b615a24c724041ef23e2c4073f2610c4c6d0)
- [Half Sword developer FAQ on modding](https://steamcommunity.com/app/2397300/discussions/0/4513255283370048156/)

## License

MIT. Copyright 2026 Noxy229. Dependency notices are in [NOTICE.md](NOTICE.md).

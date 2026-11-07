# Framework API and lifecycle

`require("NoxyForge.framework")` exposes `new(config, bridge?)`, `VERSION`, and
`register_profile(profile)`. The optional bridge is the testing seam. Production
uses the documented UE4SS adapter.

An instance supports:

- `register(plugin)`: register before `start`; IDs must be unique.
- `start()`: initialize plugins and create one cancellable game-thread timer.
- `key(key, callback)`: register once; commands are bounded and world-scoped.
- `queue(callback)`: queue a command for a valid player context. Capacity: 32.
- `own(plugin_id, key, cleanup)`: register one owned resource. Cleanup is in reverse
  acquisition order. Duplicate ownership is rejected.
- `stop()`: gate callbacks, cancel the timer, shut down plugins, clean resources.

Callbacks receive the framework instance and a freshly resolved context. The
context includes `world`, `world_id`, `pawn`, `player_id`, `controller`, and paused
state. Invalid/menu pawns do not receive gameplay updates.

## World and plugin boundaries

World identity uses UObject identity, not a map's display name. On change, the
lifecycle epoch increments, old commands are discarded, owned resources are
cleaned, and plugins receive `world_changed`. Do not keep unvalidated actor handles
across these boundaries. A same-world pawn replacement also invalidates the
epoch and invokes `player_changed`, falling back to `world_changed` for older
plugins.

A failing plugin is disabled, its shutdown hook is attempted to restore reversible
fields, and its owned resources are cleaned without stopping
unrelated plugins. Previously registered keys for the faulted plugin are gated.
Callbacks are not assumed to be physically unregistered until UE4SS unloads the
entry mod.

`ModRef.OnUnload` is a best-effort stop notification. Explicit F10 cleanup before
hot reload is the supported deterministic cleanup path; native engine cleanup is
not assumed safe on an arbitrary unload thread.

## Profiles

A profile has `id`, `accepts(bridge, pawn)`, and its own capabilities/properties.
Register additional profiles before constructing the runtime. The included
Superpowers module uses Half Sword's reflected property names and skeletal model;
registering a profile alone does not port that plugin to another game.

## Runtime mesh conventions

Mesh arrays are dense Lua lists. Triangle *values* are zero-based Unreal vertex
indices. Positions/normals use `{X,Y,Z}`; colors use `{R,G,B,A}`. Every value must
be finite. Collision is disabled for visual demonstration meshes.

The rendering service must use the exact reflected CreateMeshSection overload.
A native actor, valid component and visible material are all required for an
in-game rendering claim. See `docs/validation.md`.


`NoxyForge.geometry.black_hole(options)` returns a validated mesh model.
`NoxyForge.mesh.spawn(bridge, context, model, options)` creates a native component
and returns a handle with idempotent `destroy()`. Acquire it only on the game
thread and register cleanup immediately. Partial native construction is cleaned
before returning an error.

`NoxyForge.material.apply(bridge, component, options)` configures only this
component's material slots, creates private dynamic instances when required, and
returns a restoration/report handle. It never edits source material assets.
Discovery is opt-in and cached by an explicit world key. A setter success is not
proof that a raw cooked shader uses that parameter; inspect the visual result.

# Install and remove NoxyForge

Python 3.11 or newer is required for the deployment tool. Download the source
release and the exact UE4SS artifact linked in `ue4ss.lock.json`. The dependency
is distributed separately, with its own license. The tool rejects other hashes.

Close Half Sword. From the NoxyForge checkout, substitute your actual paths:

```sh
python tools/forge.py doctor --game-root "/path/to/Half Sword"
python tools/forge.py install --game-root "/path/to/Half Sword" \
  --dependency-zip "/downloads/UE4SS_v3.0.1-1217-g4fb9b615.zip" \
  --state "/path/to/noxyforge-state" --dry-run
python tools/forge.py install --game-root "/path/to/Half Sword" \
  --dependency-zip "/downloads/UE4SS_v3.0.1-1217-g4fb9b615.zip" \
  --state "/path/to/noxyforge-state"
```

Keep the state directory outside the game folder; it records exact file hashes
and original bytes needed for removal. Existing independent loaders are rejected.
Unknown game builds require the explicit `--allow-untested` flag and remain
unverified. Back up your saves separately before testing gameplay modifications.

On Proton, add `WINEDLLOVERRIDES="dwmapi=n,b" %command%` to the game's Steam launch
options, preserving other options. Windows does not require this environment
setting. Start the game and check `Binaries/Win64/ue4ss/UE4SS.log` for
`[NoxyForge][ready]`. Built-in UE4SS utility mods are disabled by this installer.

## Update Lua code

```sh
python tools/forge.py update --state "/path/to/noxyforge-state" --dry-run
python tools/forge.py update --state "/path/to/noxyforge-state"
```

Only previously owned Lua code is updated. Configuration, DLLs and settings are
excluded. Local edits cause a conflict, rather than being overwritten. New or
removed source files require a clean reinstall. `--allow-running` permits code
file replacement during a development session, but does not reload the mod.
Use F10 to clean up first, then restart the game. Hot reload is disabled by the
installer; enabling it is a separate developer choice.

## Remove

Close Half Sword, then run:

```sh
python tools/forge.py uninstall --state "/path/to/noxyforge-state" --dry-run
python tools/forge.py uninstall --state "/path/to/noxyforge-state"
```

The runtime UE4SS.log is archived under the state directory before empty owned
directories are removed. Unknown remaining files are preserved and reported in
`preserved_paths`; `fresh_install_blocked` identifies a remaining directory.

Modified installed files cause a conflict. Preserve your edits and resolve the
reported conflict before retrying. Never delete the state directory before
removal. Remove the `dwmapi` launch override from Steam after removing the loader.

## Build an archive

```sh
python tools/forge.py pack --out NoxyForge.zip
```

The generated mod archive excludes native dependencies. Obtain the full source
checkout to use the installer and run tests. ZIP entries have fixed timestamps
and deterministic order, making identical source produce identical archives.

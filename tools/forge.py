#!/usr/bin/env python3
"""NoxyForge packaging and reversible installation tools (stdlib only).

Copyright (c) 2026 Noxy229. SPDX-License-Identifier: MIT
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

APP_ID = 2397300
SUPPORTED_BUILD = "24185754"
EXECUTABLE = "HalfSwordUE5-Win64-Shipping.exe"
MAX_ARCHIVE_SIZE = 128 * 1024 * 1024
MAX_FILE_SIZE = 64 * 1024 * 1024
MAX_ENTRIES = 4096
REPO = Path(__file__).resolve().parents[1]
MANIFEST = "installation.json"
UPDATE = "lua-update.json"


class ForgeError(Exception):
    """A validation failure or conflict that requires a deliberate decision."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".noxyforge-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _safe_name(name: str) -> str:
    if not name or "\\" in name or ":" in name or "\x00" in name:
        raise ForgeError(f"Unsafe archive path: {name!r}")
    plain = name[:-1] if name.endswith("/") else name
    parts = plain.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(plain).is_absolute():
        raise ForgeError(f"Unsafe archive path: {name!r}")
    if plain != "dwmapi.dll" and not plain.startswith("ue4ss/") and plain != "ue4ss":
        raise ForgeError(f"Unsupported dependency layout: {name!r}")
    return plain


def _safe_target(base: Path, relative: str) -> Path:
    if base.is_symlink():
        raise ForgeError(f"Refusing symlink installation root: {base}")
    relative = _safe_name(relative)
    candidate = base.joinpath(*relative.split("/"))
    current = base
    for part in relative.split("/"):
        current = current / part
        if current.is_symlink():
            raise ForgeError(f"Refusing symlink in installation path: {current}")
    try:
        candidate.resolve().relative_to(base.resolve())
    except ValueError as error:
        raise ForgeError("Installation path escaped the game directory") from error
    return candidate


def win64_directory(game_root: Path) -> Path:
    supplied = Path(game_root).expanduser()
    if supplied.is_symlink():
        raise ForgeError("Use the real game directory, not a symlink")
    base = supplied.resolve()
    for candidate in [base, base / "HalfswordUE5/Binaries/Win64", base / "HalfSwordUE5/Binaries/Win64"]:
        if (candidate / EXECUTABLE).is_file():
            return candidate.resolve()
    raise ForgeError(f"Cannot find {EXECUTABLE} below {base}")


def game_build(base: Path) -> str | None:
    for ancestor in [base, *base.parents]:
        manifest = ancestor / f"appmanifest_{APP_ID}.acf"
        if manifest.is_file():
            match = re.search(r'"buildid"\s+"([0-9]+)"', manifest.read_text(errors="replace"))
            return match.group(1) if match else None
    return None


def game_is_running() -> bool:
    if os.name == "nt":
        process = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {EXECUTABLE}", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, check=False,
        )
        if process.returncode:
            raise ForgeError("Cannot verify whether the game is running")
        return any(row and row[0].casefold() == EXECUTABLE.casefold()
                   for row in csv.reader(io.StringIO(process.stdout)))
    proc = Path("/proc")
    if not proc.is_dir():
        raise ForgeError("Running-process checks require Windows or Linux /proc")
    for directory in proc.iterdir():
        if not directory.name.isdigit():
            continue
        try:
            first = (directory / "cmdline").read_bytes().split(b"\0", 1)[0]
            first = first.decode(errors="replace").replace("\\", "/").rsplit("/", 1)[-1]
            if first.casefold() == EXECUTABLE.casefold():
                return True
        except (OSError, ProcessLookupError):
            continue
    return False


def doctor(game_root: Path) -> dict:
    base = win64_directory(game_root)
    build = game_build(base)
    return {
        "game": "Half Sword", "steam_app_id": APP_ID, "win64": str(base),
        "build": build, "tested_build": SUPPORTED_BUILD,
        "build_matches_profile": build == SUPPORTED_BUILD,
        "game_running": game_is_running(),
        "ue4ss_present": (base / "ue4ss/UE4SS.dll").is_file(),
        "other_loader_files": [name for name in ("winmm.dll", "HSEnhancer.dll") if (base / name).exists()],
        "proton_launch_option": 'WINEDLLOVERRIDES="dwmapi=n,b" %command%',
        "notes": ["No files were changed.", "Doctor checks files/build only; inspect UE4SS.log to verify this installation starts."],
    }


def dependency_files(archive: Path, lock: dict) -> dict[str, bytes]:
    archive = Path(archive)
    if archive.stat().st_size > MAX_ARCHIVE_SIZE:
        raise ForgeError("Dependency archive exceeds size limit")
    if sha256(archive.read_bytes()) != lock.get("sha256"):
        raise ForgeError("UE4SS archive SHA-256 does not match ue4ss.lock.json")
    files: dict[str, bytes] = {}
    names: dict[str, bool] = {}
    total = 0
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > MAX_ENTRIES:
            raise ForgeError("Too many dependency archive entries")
        for entry in entries:
            name = _safe_name(entry.filename)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
                raise ForgeError(f"Unsupported archive file type: {name}")
            key = name.casefold()
            if key in names:
                raise ForgeError(f"Duplicate archive path: {name}")
            names[key] = entry.is_dir()
            if entry.is_dir():
                continue
            if entry.file_size > MAX_FILE_SIZE:
                raise ForgeError(f"Oversized dependency entry: {name}")
            total += entry.file_size
            if total > MAX_ARCHIVE_SIZE:
                raise ForgeError("Uncompressed dependency exceeds size limit")
            if entry.file_size > max(1, entry.compress_size) * 1000:
                raise ForgeError(f"Suspicious compression ratio: {name}")
            files[name] = source.read(entry)
    for name in names:
        parts = name.split("/")
        for index in range(1, len(parts)):
            if names.get("/".join(parts[:index])) is False:
                raise ForgeError("Archive uses a file as a parent directory")
    if not {"dwmapi.dll", "ue4ss/UE4SS.dll"}.issubset(files):
        raise ForgeError("Dependency archive lacks the expected UE4SS loader files")
    # Disable optional built-ins in both formats; only the framework starts.
    modules = ["CheatManagerEnablerMod", "ConsoleCommandsMod", "ConsoleEnablerMod", "SplitScreenMod",
               "LineTraceMod", "BPML_GenericFunctions", "BPModLoaderMod", "Keybinds", "NoxyForge"]
    files["ue4ss/Mods/mods.txt"] = "".join(f"{name} : {int(name == 'NoxyForge')}\r\n" for name in modules).encode()
    files["ue4ss/Mods/mods.json"] = _json_bytes([
        {"mod_name": name, "mod_enabled": name == "NoxyForge"} for name in modules
    ])
    # An enabled.txt would bypass a disabled mods.txt entry.
    if any(name.endswith("/enabled.txt") for name in files):
        raise ForgeError("Dependency unexpectedly contains auto-enabled mods")
    return files


def framework_files(repo: Path = REPO) -> dict[str, bytes]:
    repo = Path(repo)
    root = repo / "src/ue4ss/Mods"
    if not root.is_dir():
        raise ForgeError("Missing framework source directory")
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ForgeError(f"Symlink in framework sources: {path}")
        if path.is_file():
            name = "ue4ss/Mods/" + path.relative_to(root).as_posix()
            _safe_name(name)
            files[name] = path.read_bytes()
    if not files:
        raise ForgeError("No framework source files found")
    for filename in ("LICENSE", "README.md"):
        if (repo / filename).is_file():
            files["ue4ss/Mods/NoxyForge/" + filename] = (repo / filename).read_bytes()
    return files


def pack(output: Path, repo: Path = REPO) -> dict:
    files = framework_files(repo)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data, compresslevel=9)
    data = buffer.getvalue()
    _atomic_write(output, data)
    return {"archive": str(output.resolve()), "files": len(files), "sha256": sha256(data), "bytes": len(data)}


def _load_manifest(state: Path) -> dict:
    manifest = json.loads((state / MANIFEST).read_text())
    if manifest.get("schema") != 1 or not isinstance(manifest.get("entries"), list):
        raise ForgeError("Unsupported or invalid installation journal")
    if not isinstance(manifest.get("win64"), str) or not Path(manifest["win64"]).is_absolute():
        raise ForgeError("Invalid installation root in journal")
    if manifest.get("status") not in {"prepared", "installed", "uninstalled", "rolled_back"}:
        raise ForgeError("Invalid installation status")
    names = set()
    for entry in manifest["entries"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ForgeError("Invalid journal entry")
        name = _safe_name(entry["path"]).casefold()
        if name in names:
            raise ForgeError("Duplicate journal entry")
        names.add(name)
        for key in ("before_sha256", "after_sha256"):
            value = entry.get(key)
            if key == "before_sha256" and value is None:
                continue
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
                raise ForgeError("Invalid hash in installation journal")
    return manifest


def _state_path(state: Path) -> Path:
    state = Path(state).expanduser()
    if state.is_symlink():
        raise ForgeError("Installation state cannot be a symlink")
    return state.resolve()


def _check_installed(base: Path, manifest: dict) -> list[str]:
    conflicts = []
    for entry in manifest["entries"]:
        path = _safe_target(base, entry["path"])
        if not path.is_file() or sha256(path.read_bytes()) != entry["after_sha256"]:
            conflicts.append(entry["path"])
    return conflicts


def _restore(base: Path, state: Path, manifest: dict) -> None:
    """Preflight the entire journal before changing any destination."""
    conflicts = []
    backups = {}
    for entry in manifest["entries"]:
        relative = entry["path"]
        path = _safe_target(base, relative)
        current = sha256(path.read_bytes()) if path.is_file() else None
        allowed = {entry["after_sha256"], entry["before_sha256"], None}
        if path.exists() and not path.is_file() or current not in allowed:
            conflicts.append(relative)
        if entry["before_sha256"] is not None:
            backup = _safe_target(state / "originals", relative)
            if not backup.is_file() or sha256(backup.read_bytes()) != entry["before_sha256"]:
                raise ForgeError(f"Original-file backup missing or changed: {relative}")
            backups[relative] = backup.read_bytes()
    if conflicts:
        raise ForgeError("Locally changed files preserved; uninstall refused: " + ", ".join(conflicts))
    for entry in reversed(manifest["entries"]):
        relative = entry["path"]
        path = _safe_target(base, relative)
        if entry["before_sha256"] is None:
            if path.is_file():
                path.unlink()
        else:
            _atomic_write(path, backups[relative])
    _remove_owned_empty_directories(base, manifest)


def _remove_owned_empty_directories(base: Path, manifest: dict) -> None:
    directories = set()
    for entry in manifest["entries"]:
        parent = _safe_target(base, entry["path"]).parent
        while parent != base:
            directories.add(parent)
            parent = parent.parent
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        try:
            directory.rmdir()
        except OSError:
            pass


def _archive_runtime_log(base: Path, state: Path) -> list[str]:
    log = _safe_target(base, "ue4ss/UE4SS.log")
    if not log.exists():
        return []
    if not log.is_file() or log.stat().st_size > MAX_ARCHIVE_SIZE:
        raise ForgeError("Unexpected type or size for UE4SS runtime log")
    directory = state / "runtime-logs"
    if directory.is_symlink():
        raise ForgeError("Runtime log archive directory cannot be a symlink")
    directory.mkdir(exist_ok=True)
    data = log.read_bytes()
    fd, filename = tempfile.mkstemp(prefix="UE4SS-", suffix=".log", dir=directory)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    if log.is_symlink() or log.read_bytes() != data:
        raise ForgeError("Runtime log changed while archiving; source preserved")
    log.unlink()
    return [str(Path(filename))]


def _remaining_loader_paths(base: Path) -> list[str]:
    root = base / "ue4ss"
    if not root.exists():
        return []
    remaining = []
    for directory, subdirectories, filenames in os.walk(root, followlinks=False):
        for name in subdirectories + filenames:
            path = Path(directory) / name
            remaining.append(path.relative_to(base).as_posix())
            if len(remaining) >= MAX_ENTRIES:
                remaining.append("[remaining path report truncated]")
                return sorted(remaining)
    return sorted(remaining) or ["ue4ss/"]


def install(game_root: Path, archive: Path, state: Path, *, repo: Path = REPO,
            dry_run: bool = False, allow_untested: bool = False) -> dict:
    base = win64_directory(game_root)
    state = _state_path(state)
    try:
        state.relative_to(base)
    except ValueError:
        pass
    else:
        raise ForgeError("Keep installation state outside the game Win64 directory")
    lock = json.loads((Path(repo) / "ue4ss.lock.json").read_text())
    files = dependency_files(archive, lock)
    files.update(framework_files(repo))
    if (state / MANIFEST).exists():
        old = _load_manifest(state)
        if Path(old["win64"]) != base:
            raise ForgeError("State belongs to a different game directory")
        same = {entry["path"]: entry["after_sha256"] for entry in old["entries"]} == {
            path: sha256(data) for path, data in files.items()}
        if old["status"] == "installed" and same and not _check_installed(base, old):
            return {"status": "already_installed", "win64": str(base), "state": str(state)}
        raise ForgeError("State already exists; uninstall unchanged files first and use a fresh state directory")
    if state.exists() and any(state.iterdir()):
        raise ForgeError("Installation state directory is not empty")
    build = game_build(base)
    if build != SUPPORTED_BUILD and not allow_untested:
        raise ForgeError(f"Profile targets Steam build {SUPPORTED_BUILD}, found {build!r}; use --allow-untested deliberately")
    for name in ("dwmapi.dll", "winmm.dll", "HSEnhancer.dll", "ue4ss"):
        if (base / name).exists():
            raise ForgeError(f"Existing non-owned loader detected: {name}; automatic replacement refused")
    for name in files:
        _safe_target(base, name)
    summary = {"status": "dry_run" if dry_run else "installed", "win64": str(base), "state": str(state),
               "files": len(files), "dependency_sha256": lock["sha256"], "build": build,
               "proton_launch_option": 'WINEDLLOVERRIDES="dwmapi=n,b" %command%'}
    if dry_run:
        return summary
    if game_is_running():
        raise ForgeError("Close Half Sword normally before installing")
    state.mkdir(parents=True, exist_ok=True)
    entries = []
    for relative, data in sorted(files.items()):
        target = _safe_target(base, relative)
        before = target.read_bytes() if target.is_file() else None
        entry = {"path": relative, "before_sha256": sha256(before) if before is not None else None,
                 "after_sha256": sha256(data), "applied": False}
        if before is not None:
            _atomic_write(_safe_target(state / "originals", relative), before)
        entries.append(entry)
    journal = {"schema": 1, "status": "prepared", "win64": str(base), "dependency": lock,
               "build": build, "entries": entries}
    _atomic_write(state / MANIFEST, _json_bytes(journal))
    try:
        for entry in entries:
            _write_target(_safe_target(base, entry["path"]), files[entry["path"]])
            entry["applied"] = True
            _atomic_write(state / MANIFEST, _json_bytes(journal))
        journal["status"] = "installed"
        _atomic_write(state / MANIFEST, _json_bytes(journal))
    except BaseException:
        _restore(base, state, journal)
        journal["status"] = "rolled_back"
        _atomic_write(state / MANIFEST, _json_bytes(journal))
        raise
    return summary


def _write_target(path: Path, data: bytes) -> None:
    _atomic_write(path, data)


def _lua_path(name: str) -> bool:
    # Only first-party executable Lua, never settings or dependency modules.
    return (name.endswith(".lua") and name != "ue4ss/Mods/shared/NoxyForge/config.lua"
            and (name.startswith("ue4ss/Mods/NoxyForge/Scripts/")
                 or name.startswith("ue4ss/Mods/shared/NoxyForge/")))


def _recover_update(base: Path, state: Path, journal: dict) -> None:
    pending = state / UPDATE
    if not pending.exists():
        return
    if pending.is_symlink() or pending.stat().st_size > MAX_ARCHIVE_SIZE * 3:
        raise ForgeError("Unsafe or oversized Lua recovery journal")
    transaction = json.loads(pending.read_text())
    if transaction.get("schema") != 1 or not isinstance(transaction.get("files"), list):
        raise ForgeError("Invalid Lua update recovery journal")
    entries = {entry["path"]: entry for entry in journal["entries"]}
    restored = []
    seen = set()
    for item in transaction["files"]:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise ForgeError("Invalid Lua recovery entry")
        name = item["path"]
        if name in seen or not isinstance(item.get("before_hex"), str):
            raise ForgeError("Duplicate or invalid Lua recovery entry")
        seen.add(name)
        if not isinstance(item.get("after_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", item["after_sha256"]):
            raise ForgeError("Invalid Lua recovery target hash")
        if not _lua_path(name) or name not in entries:
            raise ForgeError("Unowned path in Lua recovery journal")
        before = bytes.fromhex(item["before_hex"])
        old_hash = sha256(before)
        if len(before) > MAX_FILE_SIZE or old_hash != item["before_sha256"]:
            raise ForgeError("Invalid Lua recovery backup")
        if entries[name]["after_sha256"] not in {old_hash, item["after_sha256"]}:
            raise ForgeError("Lua recovery journal does not match installation")
        target = _safe_target(base, name)
        if not target.is_file() or sha256(target.read_bytes()) not in {old_hash, item["after_sha256"]}:
            raise ForgeError("Locally changed file prevents Lua update recovery: " + name)
        restored.append((target, before, entries[name], old_hash))
    for target, before, entry, old_hash in restored:
        _atomic_write(target, before)
        entry["after_sha256"] = old_hash
    _atomic_write(state / MANIFEST, _json_bytes(journal))
    pending.unlink()


def update(state: Path, *, repo: Path = REPO, dry_run: bool = False,
           allow_running: bool = False) -> dict:
    """Atomically replace individual originally-owned Lua files, with rollback."""
    state = _state_path(state)
    journal = _load_manifest(state)
    if journal["status"] != "installed":
        raise ForgeError("Lua update requires an installed journal")
    base = win64_directory(Path(journal["win64"]))
    if not dry_run and game_is_running() and not allow_running:
        raise ForgeError("Close Half Sword or explicitly use --allow-running for Lua-only updates")
    if (state / UPDATE).exists():
        if dry_run:
            raise ForgeError("Interrupted Lua update requires recovery; run update without --dry-run")
        _recover_update(base, state, journal)
    sources = {name: data for name, data in framework_files(repo).items() if _lua_path(name)}
    entries = {entry["path"]: entry for entry in journal["entries"]}
    unowned = set(sources) - set(entries)
    if unowned:
        raise ForgeError("New Lua files require a fresh install: " + ", ".join(sorted(unowned)))
    missing = {name for name in entries if _lua_path(name)} - set(sources)
    if missing:
        raise ForgeError("Lua update cannot remove owned files: " + ", ".join(sorted(missing)))
    changes = []
    for name, data in sorted(sources.items()):
        target = _safe_target(base, name)
        if not target.is_file() or sha256(target.read_bytes()) != entries[name]["after_sha256"]:
            raise ForgeError("Locally changed Lua file preserved; update refused: " + name)
        if len(data) > MAX_FILE_SIZE:
            raise ForgeError("Oversized Lua source: " + name)
        if sha256(data) != entries[name]["after_sha256"]:
            before = target.read_bytes()
            changes.append({"path": name, "before_hex": before.hex(),
                            "before_sha256": sha256(before), "after_sha256": sha256(data)})
    summary = {"status": "dry_run" if dry_run else ("updated" if changes else "already_current"),
               "action": "lua_update", "files": [item["path"] for item in changes],
               "state": str(state), "requires_reload": bool(changes)}
    if dry_run or not changes:
        return summary
    transaction = {"schema": 1, "files": changes}
    _atomic_write(state / UPDATE, _json_bytes(transaction))
    try:
        for item in changes:
            _write_target(_safe_target(base, item["path"]), sources[item["path"]])
            entries[item["path"]]["after_sha256"] = item["after_sha256"]
        _atomic_write(state / MANIFEST, _json_bytes(journal))
    except BaseException:
        # Disk backups permit the same recovery after an interrupted process.
        _recover_update(base, state, journal)
        raise
    (state / UPDATE).unlink()
    return summary


def uninstall(state: Path, *, dry_run: bool = False) -> dict:
    state = _state_path(state)
    journal = _load_manifest(state)
    already = journal["status"] in ("uninstalled", "rolled_back")
    base = win64_directory(Path(journal["win64"]))
    if (state / UPDATE).exists():
        raise ForgeError("Pending Lua update; run update to recover before uninstalling")
    # Validate conflicts even in dry-run, without restoring yet.
    conflicts = _check_installed(base, journal) if journal["status"] == "installed" else []
    if conflicts:
        raise ForgeError("Locally changed files preserved; uninstall refused: " + ", ".join(conflicts))
    if dry_run:
        return {"status": "dry_run", "action": "uninstall", "files": 0 if already else len(journal["entries"]),
                "runtime_log_will_be_archived": (base / "ue4ss/UE4SS.log").is_file()}
    if game_is_running():
        raise ForgeError("Close Half Sword normally before uninstalling")
    archived = _archive_runtime_log(base, state)
    if not already:
        _restore(base, state, journal)
    _remove_owned_empty_directories(base, journal)
    remaining = _remaining_loader_paths(base)
    journal["status"] = "uninstalled"
    _atomic_write(state / MANIFEST, _json_bytes(journal))
    return {"status": "already_uninstalled" if already else "uninstalled", "state": str(state),
            "files": 0 if already else len(journal["entries"]), "archived_runtime_logs": archived,
            "preserved_paths": remaining, "fresh_install_blocked": bool(remaining)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    doc = sub.add_parser("doctor", help="Inspect paths, build, running process and loader conflicts")
    doc.add_argument("--game-root", required=True, type=Path)
    pkg = sub.add_parser("pack", help="Create a reproducible framework-only ZIP")
    pkg.add_argument("--out", required=True, type=Path)
    ins = sub.add_parser("install", help="Install pinned UE4SS plus NoxyForge with a rollback journal")
    ins.add_argument("--game-root", required=True, type=Path)
    ins.add_argument("--dependency-zip", required=True, type=Path)
    ins.add_argument("--state", required=True, type=Path)
    ins.add_argument("--dry-run", action="store_true")
    ins.add_argument("--allow-untested", action="store_true")
    upd = sub.add_parser("update", help="Update only unchanged originally-owned Lua code")
    upd.add_argument("--state", required=True, type=Path)
    upd.add_argument("--dry-run", action="store_true")
    upd.add_argument("--allow-running", action="store_true")
    un = sub.add_parser("uninstall", help="Remove unchanged owned files and restore originals")
    un.add_argument("--state", required=True, type=Path)
    un.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor": result = doctor(args.game_root)
        elif args.command == "pack": result = pack(args.out)
        elif args.command == "install":
            result = install(args.game_root, args.dependency_zip, args.state,
                             dry_run=args.dry_run, allow_untested=args.allow_untested)
        elif args.command == "update":
            result = update(args.state, dry_run=args.dry_run, allow_running=args.allow_running)
        else: result = uninstall(args.state, dry_run=args.dry_run)
        print(json.dumps(result, indent=2))
        return 0
    except (ForgeError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"NoxyForge: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

"""Installer regression tests. All game trees are temporary fixtures."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("forge", ROOT / "tools/forge.py")
forge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(forge)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        scripts = self.repo / "src/ue4ss/Mods/NoxyForge/Scripts"
        scripts.mkdir(parents=True)
        (scripts / "main.lua").write_text('print("NoxyForge")\n')
        self.game = self.root / "steamapps/common/Half Sword"
        self.bin = self.game / "HalfswordUE5/Binaries/Win64"
        self.bin.mkdir(parents=True)
        (self.bin / forge.EXECUTABLE).write_bytes(b"fixture executable")
        (self.root / "steamapps/appmanifest_2397300.acf").write_text('"buildid" "24185754"')
        self.archive = self.root / "dependency.zip"
        self.state = self.root / "install-state"
        self.write_archive({"dwmapi.dll": b"proxy", "ue4ss/UE4SS.dll": b"loader", "ue4ss/LICENSE": b"upstream license"})
        self.running = mock.patch.object(forge, "game_is_running", return_value=False)
        self.running.start()
        self.addCleanup(self.running.stop)

    def write_archive(self, files, extra=None):
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as z:
            for name, data in files.items():
                z.writestr(name, data)
            if extra:
                z.writestr(*extra)
        lock = {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(), "asset": "test.zip"}
        (self.repo / "ue4ss.lock.json").write_text(json.dumps(lock))
        return lock

    def install(self, **options):
        return forge.install(self.game, self.archive, self.state, repo=self.repo, **options)

    def test_doctor_identifies_build_without_mutation(self):
        before = sorted(p.relative_to(self.game).as_posix() for p in self.game.rglob("*"))
        result = forge.doctor(self.game)
        self.assertEqual(result["build"], "24185754")
        self.assertTrue(result["build_matches_profile"])
        self.assertFalse(result["ue4ss_present"])
        self.assertEqual(before, sorted(p.relative_to(self.game).as_posix() for p in self.game.rglob("*")))

    def test_archive_wrong_hash_rejected_before_state_or_game_writes(self):
        (self.repo / "ue4ss.lock.json").write_text(json.dumps({"sha256": "0" * 64}))
        with self.assertRaisesRegex(forge.ForgeError, "SHA-256"):
            self.install()
        self.assertFalse(self.state.exists())
        self.assertFalse((self.bin / "dwmapi.dll").exists())

    def test_archive_traversal_rejected(self):
        for path in ["ue4ss/../outside.txt", "../outside.txt", "/ue4ss/evil", "C:/evil", "ue4ss\\evil", "ue4ss//evil"]:
            with self.subTest(path=path):
                self.write_archive({"dwmapi.dll": b"p", "ue4ss/UE4SS.dll": b"l", path: b"evil"})
                with self.assertRaises(forge.ForgeError):
                    self.install()
        self.assertFalse((self.root / "outside.txt").exists())

    def test_archive_symlink_rejected(self):
        entry = zipfile.ZipInfo("ue4ss/link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write_archive({"dwmapi.dll": b"p", "ue4ss/UE4SS.dll": b"l"}, extra=(entry, b"/etc/passwd"))
        with self.assertRaisesRegex(forge.ForgeError, "file type"):
            self.install()

    def test_archive_unexpected_root_rejected(self):
        self.write_archive({"dwmapi.dll": b"p", "ue4ss/UE4SS.dll": b"l", "steam_api64.dll": b"not allowed"})
        with self.assertRaisesRegex(forge.ForgeError, "layout"):
            self.install()

    def test_case_collisions_rejected_for_windows(self):
        self.write_archive({"dwmapi.dll": b"p", "ue4ss/UE4SS.dll": b"l", "UE4SS/ue4ss.dll": b"collision"})
        with self.assertRaises(forge.ForgeError):
            self.install()

    def test_file_parent_collision_rejected(self):
        self.write_archive({"dwmapi.dll": b"p", "ue4ss/UE4SS.dll": b"l", "ue4ss/data": b"file", "ue4ss/data/child": b"child"})
        with self.assertRaisesRegex(forge.ForgeError, "parent"):
            self.install()

    def test_zip_bomb_limits_checked_before_extracting(self):
        with mock.patch.object(forge, "MAX_ARCHIVE_SIZE", 10):
            with self.assertRaisesRegex(forge.ForgeError, "size limit"):
                self.install()

    def test_only_noxyforge_enabled_in_both_upstream_mod_formats(self):
        self.install()
        txt = (self.bin / "ue4ss/Mods/mods.txt").read_text()
        self.assertIn("NoxyForge : 1", txt)
        self.assertNotIn("Keybinds : 1", txt)
        records = json.loads((self.bin / "ue4ss/Mods/mods.json").read_text())
        self.assertEqual([r["mod_name"] for r in records if r["mod_enabled"]], ["NoxyForge"])

    def test_install_and_uninstall_are_idempotent(self):
        self.assertEqual(self.install()["status"], "installed")
        journal = (self.state / forge.MANIFEST).read_bytes()
        self.assertEqual(self.install()["status"], "already_installed")
        self.assertEqual(journal, (self.state / forge.MANIFEST).read_bytes())
        self.assertEqual(forge.uninstall(self.state)["status"], "uninstalled")
        self.assertEqual(forge.uninstall(self.state)["status"], "already_uninstalled")
        self.assertFalse((self.bin / "ue4ss").exists())
        self.assertFalse((self.bin / "dwmapi.dll").exists())
        self.assertTrue((self.bin / forge.EXECUTABLE).exists())

    def test_failed_second_write_rolls_back_whole_install(self):
        original = forge._write_target
        writes = 0
        def fail(path, data):
            nonlocal writes
            writes += 1
            if writes == 2:
                raise OSError("fixture disk failure")
            original(path, data)
        with mock.patch.object(forge, "_write_target", side_effect=fail):
            with self.assertRaisesRegex(OSError, "fixture disk failure"):
                self.install()
        self.assertFalse((self.bin / "dwmapi.dll").exists())
        self.assertFalse((self.bin / "ue4ss").exists())
        journal = json.loads((self.state / forge.MANIFEST).read_text())
        self.assertEqual(journal["status"], "rolled_back")

    def test_changed_local_file_blocks_entire_uninstall(self):
        self.install()
        edited = self.bin / "ue4ss/Mods/NoxyForge/Scripts/main.lua"
        edited.write_bytes(b"local user change")
        with self.assertRaisesRegex(forge.ForgeError, "Locally changed"):
            forge.uninstall(self.state)
        self.assertEqual(edited.read_bytes(), b"local user change")
        self.assertTrue((self.bin / "dwmapi.dll").is_file())
        self.assertTrue((self.bin / "ue4ss/UE4SS.dll").is_file())

    def test_uninstall_preserves_untracked_user_file_and_directory(self):
        self.install()
        custom = self.bin / "ue4ss/MyUserNote.txt"
        custom.write_text("keep")
        forge.uninstall(self.state)
        self.assertEqual(custom.read_text(), "keep")
        self.assertFalse((self.bin / "dwmapi.dll").exists())

    def test_uninstall_archives_exact_runtime_log_and_allows_fresh_install(self):
        self.install()
        log = self.bin / "ue4ss/UE4SS.log"
        log.write_bytes(b"runtime diagnostics")
        preview = forge.uninstall(self.state, dry_run=True)
        self.assertTrue(preview["runtime_log_will_be_archived"])
        self.assertTrue(log.exists())
        result = forge.uninstall(self.state)
        self.assertEqual(len(result["archived_runtime_logs"]), 1)
        archived = Path(result["archived_runtime_logs"][0])
        self.assertEqual(archived.parent, self.state / "runtime-logs")
        self.assertEqual(archived.read_bytes(), b"runtime diagnostics")
        self.assertFalse((self.bin / "ue4ss").exists())
        self.assertFalse(result["fresh_install_blocked"])
        forge.install(self.game, self.archive, self.root / "new-state", repo=self.repo)

    def test_unknown_runtime_file_is_preserved_and_reported(self):
        self.install()
        unknown = self.bin / "ue4ss/Unknown.log"
        unknown.write_bytes(b"user diagnostics")
        (self.bin / "ue4ss/UE4SS.log").write_bytes(b"known log")
        result = forge.uninstall(self.state)
        self.assertEqual(unknown.read_bytes(), b"user diagnostics")
        self.assertEqual(result["preserved_paths"], ["ue4ss/Unknown.log"])
        self.assertTrue(result["fresh_install_blocked"])
        with self.assertRaisesRegex(forge.ForgeError, "non-owned"):
            forge.install(self.game, self.archive, self.root / "new-state", repo=self.repo)

    def test_repeat_uninstall_can_archive_residual_log_from_older_version(self):
        self.install()
        forge.uninstall(self.state)
        log = self.bin / "ue4ss/UE4SS.log"
        log.parent.mkdir()
        log.write_bytes(b"old residual")
        result = forge.uninstall(self.state)
        self.assertEqual(result["status"], "already_uninstalled")
        self.assertEqual(Path(result["archived_runtime_logs"][0]).read_bytes(), b"old residual")
        self.assertFalse(log.parent.exists())

    def test_runtime_log_symlink_is_never_archived_or_deleted(self):
        self.install()
        external = self.root / "private.log"
        external.write_bytes(b"untouched")
        log = self.bin / "ue4ss/UE4SS.log"
        log.symlink_to(external)
        with self.assertRaisesRegex(forge.ForgeError, "symlink"):
            forge.uninstall(self.state)
        self.assertTrue(log.is_symlink())
        self.assertEqual(external.read_bytes(), b"untouched")
        self.assertTrue((self.bin / "dwmapi.dll").exists())

    def test_uninstall_restores_original_from_journal(self):
        self.install()
        journal_path = self.state / forge.MANIFEST
        journal = json.loads(journal_path.read_text())
        entry = next(e for e in journal["entries"] if e["path"] == "ue4ss/LICENSE")
        original = b"prior original content"
        entry["before_sha256"] = forge.sha256(original)
        backup = self.state / "originals/ue4ss/LICENSE"
        backup.parent.mkdir(parents=True)
        backup.write_bytes(original)
        journal_path.write_text(json.dumps(journal))
        forge.uninstall(self.state)
        self.assertEqual((self.bin / "ue4ss/LICENSE").read_bytes(), original)

    def test_existing_non_owned_loader_not_overwritten(self):
        (self.bin / "winmm.dll").write_bytes(b"another mod")
        with self.assertRaisesRegex(forge.ForgeError, "non-owned loader"):
            self.install()
        self.assertEqual((self.bin / "winmm.dll").read_bytes(), b"another mod")
        self.assertFalse(self.state.exists())

    def test_running_game_blocks_real_install_but_allows_dry_run(self):
        with mock.patch.object(forge, "game_is_running", return_value=True):
            with self.assertRaisesRegex(forge.ForgeError, "Close Half Sword"):
                self.install()
            self.assertEqual(self.install(dry_run=True)["status"], "dry_run")
        self.assertFalse(self.state.exists())
        self.assertFalse((self.bin / "dwmapi.dll").exists())

    def test_untested_build_requires_explicit_flag(self):
        (self.root / "steamapps/appmanifest_2397300.acf").write_text('"buildid" "999"')
        with self.assertRaisesRegex(forge.ForgeError, "24185754"):
            self.install()
        self.assertEqual(self.install(dry_run=True, allow_untested=True)["status"], "dry_run")

    def test_reproducible_pack_ignores_file_timestamps(self):
        a, b = self.root / "a.zip", self.root / "b.zip"
        first = forge.pack(a, self.repo)
        path = self.repo / "src/ue4ss/Mods/NoxyForge/Scripts/main.lua"
        os.utime(path, (1234567890, 1234567890))
        second = forge.pack(b, self.repo)
        self.assertEqual(a.read_bytes(), b.read_bytes())
        self.assertEqual(first["sha256"], second["sha256"])
        with zipfile.ZipFile(a) as z:
            self.assertEqual(z.namelist(), ["ue4ss/Mods/NoxyForge/Scripts/main.lua"])

    def test_target_parent_symlink_rejected(self):
        other = self.root / "other"
        other.mkdir()
        (self.bin / "ue4ss").symlink_to(other, target_is_directory=True)
        with self.assertRaises(forge.ForgeError):
            self.install()
        self.assertEqual(list(other.iterdir()), [])

    def change_source(self, name="main.lua", data=b"updated Lua"):
        source = self.repo / "src/ue4ss/Mods/NoxyForge/Scripts" / name
        source.write_bytes(data)
        return source

    def test_lua_update_is_idempotent_and_uninstall_uses_latest_hash(self):
        self.install()
        self.change_source()
        result = forge.update(self.state, repo=self.repo)
        self.assertEqual(result["status"], "updated")
        self.assertEqual(len(result["files"]), 1)
        target = self.bin / result["files"][0]
        self.assertEqual(target.read_bytes(), b"updated Lua")
        self.assertEqual(forge.update(self.state, repo=self.repo)["status"], "already_current")
        self.assertEqual(forge.uninstall(self.state)["status"], "uninstalled")

    def test_update_requires_explicit_running_permission_and_dry_run_does_not_write(self):
        self.install()
        self.change_source()
        before = (self.state / forge.MANIFEST).read_bytes()
        with mock.patch.object(forge, "game_is_running", return_value=True):
            with self.assertRaisesRegex(forge.ForgeError, "allow-running"):
                forge.update(self.state, repo=self.repo)
            self.assertEqual(forge.update(self.state, repo=self.repo, dry_run=True)["status"], "dry_run")
            self.assertEqual((self.state / forge.MANIFEST).read_bytes(), before)
            self.assertEqual(forge.update(self.state, repo=self.repo, allow_running=True)["status"], "updated")

    def test_update_refuses_local_changes_new_files_and_removed_files(self):
        self.install()
        target = self.bin / "ue4ss/Mods/NoxyForge/Scripts/main.lua"
        original = target.read_bytes()
        target.write_bytes(b"user edit")
        self.change_source()
        with self.assertRaisesRegex(forge.ForgeError, "Locally changed"):
            forge.update(self.state, repo=self.repo)
        self.assertEqual(target.read_bytes(), b"user edit")
        target.write_bytes(original)
        extra = self.change_source("new.lua")
        with self.assertRaisesRegex(forge.ForgeError, "New Lua"):
            forge.update(self.state, repo=self.repo)
        extra.unlink()
        (self.repo / "src/ue4ss/Mods/NoxyForge/Scripts/main.lua").unlink()
        with self.assertRaisesRegex(forge.ForgeError, "source files|remove owned"):
            forge.update(self.state, repo=self.repo)

    def test_update_never_changes_dependency_or_settings(self):
        config = self.repo / "src/ue4ss/Mods/shared/NoxyForge/config.lua"
        config.parent.mkdir(parents=True)
        config.write_bytes(b"original config")
        self.install()
        self.change_source()
        config.write_bytes(b"changed config")
        loader = self.bin / "ue4ss/UE4SS.dll"
        forge.update(self.state, repo=self.repo)
        self.assertEqual(loader.read_bytes(), b"loader")
        self.assertEqual((self.bin / "ue4ss/Mods/shared/NoxyForge/config.lua").read_bytes(), b"original config")

    def test_update_second_write_failure_restores_all_files_and_journal(self):
        self.change_source("second.lua", b"second original")
        self.install()
        before = (self.state / forge.MANIFEST).read_bytes()
        self.change_source()
        self.change_source("second.lua", b"second updated")
        original = forge._write_target
        calls = 0
        def fail(path, data):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("fixture update failure")
            original(path, data)
        with mock.patch.object(forge, "_write_target", side_effect=fail):
            with self.assertRaisesRegex(OSError, "update failure"):
                forge.update(self.state, repo=self.repo)
        self.assertEqual((self.state / forge.MANIFEST).read_bytes(), before)
        self.assertFalse((self.state / forge.UPDATE).exists())
        self.assertEqual((self.bin / "ue4ss/Mods/NoxyForge/Scripts/second.lua").read_bytes(), b"second original")
        self.assertEqual(forge.uninstall(self.state)["status"], "uninstalled")

    def test_interrupted_update_recovers_before_retry(self):
        self.install()
        name = "ue4ss/Mods/NoxyForge/Scripts/main.lua"
        target = self.bin / name
        before = target.read_bytes()
        after = b"interrupted replacement"
        transaction = {"schema": 1, "files": [{"path": name, "before_hex": before.hex(),
            "before_sha256": forge.sha256(before), "after_sha256": forge.sha256(after)}]}
        (self.state / forge.UPDATE).write_bytes(forge._json_bytes(transaction))
        target.write_bytes(after)
        with self.assertRaisesRegex(forge.ForgeError, "Pending Lua"):
            forge.uninstall(self.state)
        self.assertEqual(forge.update(self.state, repo=self.repo)["status"], "already_current")
        self.assertEqual(target.read_bytes(), before)
        self.assertFalse((self.state / forge.UPDATE).exists())

    def test_tampered_journal_path_rejected(self):
        self.install()
        p = self.state / forge.MANIFEST
        data = json.loads(p.read_text())
        data["entries"][0]["path"] = "../../outside"
        p.write_text(json.dumps(data))
        with self.assertRaises(forge.ForgeError):
            forge.uninstall(self.state)

if __name__ == "__main__":
    unittest.main()

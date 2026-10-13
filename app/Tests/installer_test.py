#!/usr/bin/env python3
"""Disposable fixtures only: no macOS launch, build, network or live workspace."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "installer.py")
i = importlib.util.module_from_spec(spec)
spec.loader.exec_module(i)
SHA = "a" * 40

def bundle(path, version="new", recovery=1):
    binary = path / "Contents/MacOS/SproutRecruit"
    binary.parent.mkdir(parents=True)
    binary.write_text(version)
    binary.chmod(0o700)
    with open(path / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": i.BUNDLE, "CFBundleExecutable": "SproutRecruit", "CFBundleShortVersionString": version, "CFBundleVersion": "1", "SproutRecoveryCLIVersion": recovery}, handle)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        # /tmp is an alias on macOS; resolve it before testing symlink rejection.
        self.temp = tempfile.TemporaryDirectory()
        # Simulate atomic exchange for cross-platform fixtures; the real macOS
        # primitive is separately exercised with disposable paths.
        def fixture_swap(first, second):
            temporary = Path(first).with_name("fixture-exchange")
            os.rename(first, temporary)
            os.rename(second, first)
            os.rename(temporary, second)
        self.swap_mock = patch.object(i, "swap_paths", side_effect=fixture_swap)
        self.swap_mock.start()
        self.addCleanup(self.swap_mock.stop)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.repo = self.root / "repo"
        self.home.mkdir(); self.repo.mkdir()
        self.calls = []
        self.running = False
        self.dirty = False
        self.saved = ""
        self.compatible = True
        self.bad_backup = False
        self.os_version = "26.6.2"
        self.tool = i.Installer(self.repo, self.home, self.run_command)

    def tearDown(self):
        self.temp.cleanup()

    def run_command(self, args, **kwargs):
        args = [str(x) for x in args]
        self.calls.append(args)
        if args[0] == "/usr/bin/uname": return "arm64"
        if args[0] == "/usr/bin/sw_vers": return self.os_version
        if args[0] in {"/usr/bin/xcrun", "/usr/bin/xcode-select", "/usr/bin/codesign"}: return ""
        if args[0] == "/usr/bin/lipo": return "arm64"
        if args[0] == "/bin/ps": return "/test/SproutRecruit" if self.running else "other"
        if args[0] == "/usr/bin/defaults":
            if self.saved: return self.saved
            raise i.InstallError("No saved path")
        if args[0] == "/usr/bin/git": return " M app/source" if "status" in args and self.dirty else "" if "status" in args else SHA
        if args[0] == "/bin/zsh":
            bundle(Path(kwargs["env"]["SPROUT_OUTPUT"]))
            return "Built"
        if "--backup-workspace" in args:
            workspace, backup_root = Path(args[2]), Path(args[4])
            self.assertNotEqual(backup_root.parent, workspace.parent)
            self.assertFalse(str(backup_root).startswith(str(workspace.parent) + "/"))
            return json.dumps({"verified": not self.bad_backup, "snapshotPath": str(self.root / "snapshot"), "sourceDatabase": args[2]})
        if "--workspace-compatible" in args:
            return json.dumps({"compatible": self.compatible, "schemaVersion": 1, "supportedSchemaVersion": 1})
        raise AssertionError(args)

    def existing(self, recovery=1):
        bundle(self.tool.target, "old", recovery)
        self.tool.support.mkdir(parents=True)
        db = self.tool.support / "SproutRecruit.sqlite"
        db.write_bytes(b"untouched workspace fixture")
        return db

    def test_check_is_read_only(self):
        plan = self.tool.install(SHA, check_only=True)
        self.assertEqual(plan["status"], "preflight-passed")
        self.assertFalse(self.tool.apps.exists())

    def test_fresh_install_receipt_and_no_launch(self):
        result = self.tool.install(SHA)
        self.assertTrue(self.tool.target.exists())
        self.assertFalse((self.tool.support / "SproutRecruit.sqlite").exists())
        self.assertEqual(json.loads(Path(result["receipt"]).read_text())["commit"], SHA)
        self.assertEqual(Path(result["receipt"]).stat().st_mode & 0o777, 0o600)
        self.assertFalse(any("/usr/bin/open" in x for x in self.calls))

    def test_update_and_code_rollback_preserve_database(self):
        db = self.existing()
        before = db.read_bytes()
        result = self.tool.install(SHA)
        self.assertEqual(db.read_bytes(), before)
        self.assertTrue(Path(result["previousApp"]).exists())
        rolled = self.tool.rollback(result["receipt"])
        self.assertFalse(rolled["workspaceRestored"])
        self.assertEqual(db.read_bytes(), before)
        self.assertEqual((self.tool.target / "Contents/MacOS/SproutRecruit").read_text(), "old")

    def test_incompatible_upgrade_blocks_before_backup_or_swap(self):
        self.existing(); self.compatible = False
        with self.assertRaisesRegex(i.InstallError, "cannot read"):
            self.tool.install(SHA)
        self.assertFalse(any("--backup-workspace" in x for x in self.calls))
        self.assertEqual((self.tool.target / "Contents/MacOS/SproutRecruit").read_text(), "old")

    def test_failed_backup_preserves_old_app(self):
        self.existing(); self.bad_backup = True
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        self.assertEqual((self.tool.target / "Contents/MacOS/SproutRecruit").read_text(), "old")

    def test_running_app_blocks_before_mutation(self):
        self.running = True
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        self.assertFalse(self.tool.apps.exists())

    def test_dirty_and_wrong_commit_block(self):
        self.dirty = True
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        self.dirty = False
        with self.assertRaises(i.InstallError): self.tool.install("b" * 40)
        self.assertFalse(self.tool.apps.exists())

    def test_unsupported_system_blocks(self):
        self.os_version = "27.0"
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        self.assertFalse(self.tool.apps.exists())

    def test_symlink_and_parent_traversal_block(self):
        link = self.home / "Applications"
        link.symlink_to(self.repo)
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        with self.assertRaises(i.InstallError): i.safe_path(self.home / "../escape")

    def test_old_app_missing_compatibility_never_invoked(self):
        self.existing(recovery=0)
        result = self.tool.install(SHA)
        with self.assertRaisesRegex(i.InstallError, "predates"): self.tool.rollback(result["receipt"])
        self.assertFalse(any("--workspace-compatible" in x and "previous.app" in x[0] for x in self.calls))

    def test_incompatible_workspace_blocks_rollback(self):
        self.existing()
        result = self.tool.install(SHA)
        self.compatible = False
        with self.assertRaises(i.InstallError): self.tool.rollback(result["receipt"])
        self.assertEqual((self.tool.target / "Contents/MacOS/SproutRecruit").read_text(), "new")

    def test_failed_swap_preserves_previous_app(self):
        self.existing()
        with patch.object(i, "swap_paths", side_effect=OSError("fixture disk failure")):
            with self.assertRaises(OSError): self.tool.install(SHA)
        self.assertEqual((self.tool.target / "Contents/MacOS/SproutRecruit").read_text(), "old")

    def test_existing_lock_does_not_get_removed(self):
        self.tool.apps.mkdir()
        self.tool.lock.mkdir()
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        self.assertTrue(self.tool.lock.exists())

    def test_unregistered_legacy_workspace_blocks(self):
        db = self.repo / "app/Data/SproutRecruit.sqlite"
        db.parent.mkdir(parents=True); db.write_text("legacy")
        with self.assertRaisesRegex(i.InstallError, "legacyWorkspacePath"): self.tool.install(SHA)
        self.assertEqual(db.read_text(), "legacy")

    def test_missing_saved_workspace_blocks(self):
        self.saved = str(self.root / "missing.sqlite")
        with self.assertRaises(i.InstallError): self.tool.install(SHA)
        self.assertFalse(self.tool.apps.exists())

    def test_modified_bundle_blocks_rollback(self):
        self.existing()
        result = self.tool.install(SHA)
        (self.tool.target / "Contents/Resources").mkdir()
        (self.tool.target / "Contents/Resources/changed.txt").write_text("changed UI")
        with self.assertRaisesRegex(i.InstallError, "contents changed"):
            self.tool.rollback(result["receipt"])

    def test_missing_original_workspace_blocks_rollback(self):
        db = self.existing()
        result = self.tool.install(SHA)
        db.unlink()
        with self.assertRaisesRegex(i.InstallError, "original workspace is missing"):
            self.tool.rollback(result["receipt"])

    def test_receipt_outside_private_folder_is_rejected(self):
        self.existing()
        result = self.tool.install(SHA)
        wrong = self.root / "copied-receipt.json"
        wrong.write_text(Path(result["receipt"]).read_text())
        with self.assertRaisesRegex(i.InstallError, "Install Receipts"):
            self.tool.rollback(wrong)

    def test_private_payload_in_bundle_is_rejected(self):
        path = self.root / "private.app"
        bundle(path)
        (path / "Contents/private.sqlite-wal").write_text("private")
        with self.assertRaises(i.InstallError): i.inspect_bundle(path, self.run_command)

@unittest.skipUnless(sys.platform == "darwin", "macOS atomic exchange primitive")
class NativeAtomicExchangeTests(unittest.TestCase):
    def test_real_atomic_exchange_with_disposable_directories(self):
        with tempfile.TemporaryDirectory() as root:
            first, second = Path(root).resolve() / "first", Path(root).resolve() / "second"
            first.mkdir(); second.mkdir()
            (first / "value").write_text("one"); (second / "value").write_text("two")
            i.swap_paths(first, second)
            self.assertEqual((first / "value").read_text(), "two")
            self.assertEqual((second / "value").read_text(), "one")

if __name__ == "__main__":
    unittest.main()

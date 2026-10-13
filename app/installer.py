#!/usr/bin/env python3
"""Supervised source-build installer. Never moves or restores a workspace."""
import argparse
import datetime
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid

APP = "Sprout Recruit.app"
BUNDLE = "com.sprout.recruit.local"
BASELINE = "26.6.2"

class InstallError(Exception):
    pass

def command(args, **kwargs):
    result = subprocess.run([str(x) for x in args], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise InstallError(f"{args[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()

def safe_path(path):
    """Reject symlink ancestors, lexical traversal and non-owned existing endpoints."""
    path = Path(path).expanduser()
    if not path.is_absolute() or ".." in path.parts:
        raise InstallError("Use an absolute path without parent traversal.")
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise InstallError(f"Symlinks are not accepted: {item}")
    if path.exists() and path.stat().st_uid != os.getuid():
        raise InstallError(f"Path is not owned by this user: {path}")
    return path

def private_dir(path):
    safe_path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise InstallError(f"Expected directory: {path}")
    path.chmod(0o700)

def write_json(path, value):
    safe_path(path)
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with open(temp, "x", encoding="utf-8") as handle:
        os.chmod(temp, 0o600)
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp, path)

def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

def inspect_bundle(path, run=command):
    safe_path(path)
    for entry in path.rglob("*"):
        if entry.is_symlink():
            raise InstallError(f"Unexpected symlink in app bundle: {entry}")
        if entry.name in {"Data", ".env"} or (entry.is_file() and (".sqlite" in entry.name.lower() or entry.suffix.lower() in {".db", ".csv", ".pem", ".key", ".p12"})):
            raise InstallError("App bundle contains an unexpected private-data file.")
    with open(path / "Contents/Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != BUNDLE or info.get("CFBundleExecutable") != "SproutRecruit":
        raise InstallError("Unexpected app identity.")
    executable = path / "Contents/MacOS/SproutRecruit"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise InstallError("App executable is missing.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path])
    if run(["/usr/bin/lipo", "-archs", executable]) != "arm64":
        raise InstallError("The pilot app must contain only the approved arm64 architecture.")
    tree = hashlib.sha256()
    for entry in sorted(path.rglob("*")):
        if entry.is_file():
            tree.update(str(entry.relative_to(path)).encode("utf-8") + b"\0")
            tree.update(str(entry.stat().st_mode & 0o777).encode("ascii") + b"\0")
            tree.update(bytes.fromhex(digest(entry)))
    return {"bundleSHA256": tree.hexdigest(), "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"), "executableSHA256": digest(executable), "recoveryCLIVersion": info.get("SproutRecoveryCLIVersion", 0)}

def swap_paths(first, second):
    """Atomically exchange two existing same-filesystem paths on macOS."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename_swap = libc.renamex_np
    rename_swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename_swap.restype = ctypes.c_int
    if rename_swap(os.fsencode(first), os.fsencode(second), 2) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

def require_quit(run=command):
    processes = run(["/bin/ps", "-axo", "comm="])
    if any(Path(line.strip()).name == "SproutRecruit" for line in processes.splitlines()):
        raise InstallError("Quit every Sprout Recruit window/app before installing or rolling back. Nothing was replaced.")

class Installer:
    def __init__(self, repo, home, run=command):
        self.repo, self.home, self.run = Path(repo), Path(home), run
        self.apps = self.home / "Applications"
        self.target = self.apps / APP
        self.support = self.home / "Library/Application Support/Sprout Recruit"
        self.history = self.apps / ".SproutRecruitInstallations"
        self.receipts = self.support.parent / "Sprout Recruit Install Receipts"
        self.lock = self.apps / ".SproutRecruit-install.lock"

    def preflight(self):
        if os.getuid() == 0:
            raise InstallError("Run as the recruiter, without sudo.")
        if self.run(["/usr/bin/uname", "-m"]) != "arm64":
            raise InstallError("Only Apple Silicon is supported by this pilot.")
        version = self.run(["/usr/bin/sw_vers", "-productVersion"])
        if version.split(".")[:2] != BASELINE.split(".")[:2]:
            raise InstallError(f"This pilot is validated only for macOS 26.6.x (first baseline {BASELINE}); this Mac has {version}. Review and validate this device before expanding support.")
        self.run(["/usr/bin/xcode-select", "-p"])
        self.run(["/usr/bin/xcrun", "swift", "--version"])
        for path in (self.apps, self.target, self.support, self.history, self.receipts):
            safe_path(path)
        require_quit(self.run)
        return version

    def workspace(self, explicit=None):
        default = self.support / "SproutRecruit.sqlite"
        try:
            saved = self.run(["/usr/bin/defaults", "read", BUNDLE, "legacyWorkspacePath"])
        except InstallError:
            saved = ""
        legacy = self.repo / "app/Data/SproutRecruit.sqlite"
        selected = Path(explicit).expanduser() if explicit else Path(saved) if saved else legacy if legacy.exists() else default
        safe_path(selected)
        if explicit and saved and str(selected) != saved:
            raise InstallError("Explicit workspace differs from the saved app workspace. Resolve this before installation.")
        if (explicit or saved) and not selected.is_file():
            raise InstallError("The existing workspace is missing; no replacement database will be created.")
        if selected.exists() and not selected.is_file():
            raise InstallError("Workspace is not a regular file.")
        if selected != default and not saved:
            # An installed app cannot discover a source-adjacent database. Do not
            # create a new workspace or change path-keyed Keychain identities.
            raise InstallError("Legacy workspace has no saved legacyWorkspacePath. Open the existing app first to register its workspace; then quit and retry.")
        return selected

    def enter(self):
        self.apps.mkdir(parents=True, exist_ok=True)
        safe_path(self.lock)
        try:
            self.lock.mkdir(mode=0o700)
        except FileExistsError:
            raise InstallError(f"Another installation or interrupted run holds {self.lock}. Review its receipt before removing the lock.")
        private_dir(self.history)
        private_dir(self.receipts)

    def install(self, commit, explicit=None, check_only=False):
        os_version = self.preflight()
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise InstallError("--commit must be an owner-reviewed full 40-character commit SHA.")
        actual = self.run(["/usr/bin/git", "-C", self.repo, "rev-parse", "HEAD"])
        if actual != commit:
            raise InstallError("Checkout HEAD differs from the approved commit. No checkout or reset was performed.")
        if self.run(["/usr/bin/git", "-C", self.repo, "status", "--porcelain", "--untracked-files=normal"]):
            raise InstallError("Source checkout has local changes. Preserve and review them before building.")
        workspace = self.workspace(explicit)
        plan = {"commit": commit, "target": str(self.target), "workspace": str(workspace), "workspaceExists": workspace.exists(), "os": os_version, "architecture": "arm64"}
        if check_only:
            return {"status": "preflight-passed", **plan}
        self.enter()
        receipt_path = None
        transaction = None
        try:
            transaction = self.history / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12])
            private_dir(transaction)
            receipt_path = self.receipts / (transaction.name + ".json")
            staged = transaction / "staged.app"
            previous = transaction / "previous.app"
            receipt = {**plan, "schema": 1, "transaction": str(transaction), "previousApp": str(previous), "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": "building"}
            write_json(receipt_path, receipt)
            env = os.environ.copy()
            env.update(SPROUT_OUTPUT=str(staged), SPROUT_ARCH="arm64")
            self.run(["/bin/zsh", self.repo / "app/build.sh"], env=env)
            receipt["installedBundle"] = inspect_bundle(staged, self.run)
            if self.target.exists():
                receipt["previousBundle"] = inspect_bundle(self.target, self.run)
            if workspace.exists():
                if receipt["installedBundle"]["recoveryCLIVersion"] < 1:
                    raise InstallError("New app does not advertise the recovery CLI. App was not replaced.")
                executable = staged / "Contents/MacOS/SproutRecruit"
                compatibility = json.loads(self.run([executable, "--workspace-compatible", "--db", workspace]))
                if compatibility.get("compatible") is not True:
                    raise InstallError("This build cannot read the current workspace schema. App was not replaced.")
                receipt["workspaceCompatibility"] = compatibility
                recovery_root = workspace.parent.parent / "Sprout Recovery" / hashlib.sha256(str(workspace).encode("utf-8")).hexdigest()[:20]
                safe_path(recovery_root)
                backup = json.loads(self.run([executable, "--backup-workspace", workspace, "--backup-root", recovery_root, "--reason", "pre-update"]))
                if backup.get("verified") is not True or not backup.get("snapshotPath") or backup.get("sourceDatabase") != str(workspace):
                    raise InstallError("Recovery tool did not return a verified snapshot. App was not replaced.")
                receipt["workspaceSnapshot"] = backup
            receipt["status"] = "prepared"
            write_json(receipt_path, receipt)
            require_quit(self.run)
            if self.target.exists():
                swap_paths(staged, self.target)
                # After the atomic exchange the old app is still safely retained
                # at staged.app, even if this bookkeeping rename is interrupted.
                os.rename(staged, previous)
            else:
                os.rename(staged, self.target)
            receipt["status"] = "installed-awaiting-acceptance"
            write_json(receipt_path, receipt)
            return {**receipt, "receipt": str(receipt_path), "next": "Open the installed app and complete the documented acceptance checks. No app was launched automatically."}
        finally:
            self.lock.rmdir()

    def rollback(self, receipt_path):
        self.preflight()
        path = safe_path(Path(receipt_path).expanduser())
        if path.parent != self.receipts or path.suffix != ".json":
            raise InstallError("Choose an installation receipt in this user's Sprout Recruit Install Receipts folder.")
        receipt = json.loads(path.read_text())
        transaction = safe_path(Path(receipt["transaction"]))
        if transaction.parent != self.history or receipt.get("target") != str(self.target):
            raise InstallError("Receipt does not identify this user's installation.")
        previous = transaction / "previous.app"
        if receipt.get("status") != "installed-awaiting-acceptance" or receipt.get("previousApp") != str(previous):
            raise InstallError("This receipt does not have an eligible retained app to roll back.")
        if inspect_bundle(previous, self.run) != receipt.get("previousBundle") or inspect_bundle(self.target, self.run) != receipt.get("installedBundle"):
            raise InstallError("App contents changed since installation. Rollback needs review.")
        if receipt.get("workspaceExists") and not Path(receipt["workspace"]).is_file():
            raise InstallError("The original workspace is missing. Resolve it before rollback.")
        workspace = self.workspace(receipt["workspace"] if Path(receipt["workspace"]).exists() else None)
        if str(workspace) != receipt["workspace"]:
            raise InstallError("Workspace location changed since installation. Review before rollback.")
        if workspace.exists():
            if receipt.get("previousBundle", {}).get("recoveryCLIVersion", 0) < 1:
                raise InstallError("Retained app predates compatibility checks. An engineer must verify a compatible recovery route; automatic rollback is blocked.")
            compatible = json.loads(self.run([previous / "Contents/MacOS/SproutRecruit", "--workspace-compatible", "--db", workspace]))
            if compatible.get("compatible") is not True:
                raise InstallError("The previous app cannot read this workspace. Use a reviewed restore procedure; no data was restored or discarded.")
        self.enter()
        displaced = transaction / "rolled-back.app"
        try:
            if displaced.exists():
                raise InstallError("A previous rollback is already retained.")
            require_quit(self.run)
            swap_paths(previous, self.target)
            os.rename(previous, displaced)
            receipt["status"] = "rolled-back"
            receipt["rolledBackAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            write_json(path, receipt)
            return {"status": "rolled-back", "receipt": str(path), "workspaceRestored": False, "target": str(self.target)}
        finally:
            self.lock.rmdir()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    install = sub.add_parser("install")
    install.add_argument("--commit", required=True)
    install.add_argument("--workspace")
    install.add_argument("--check", action="store_true", help="Read-only preflight; no build, backup or installation.")
    rollback = sub.add_parser("rollback")
    rollback.add_argument("--receipt", required=True)
    args = parser.parse_args()
    installer = Installer(Path(__file__).resolve().parent.parent, Path.home())
    try:
        output = installer.install(args.commit, args.workspace, args.check) if args.action == "install" else installer.rollback(args.receipt)
        print(json.dumps(output, indent=2, sort_keys=True))
    except (InstallError, OSError, ValueError, KeyError) as error:
        print(f"Install stopped: {error}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())

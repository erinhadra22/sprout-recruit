# Install and update Sprout Recruit with Codex

Scope: supervised internal Sprout source-build pilot, Apple Silicon Mac. Current first-device baseline is macOS 26.6.2 (25G83). The repository now includes a guarded installer and code rollback tool. Installation acceptance on a separate standard user account and another recruiter device remains unverified; fixture tests are not device acceptance. Do not onboard other recruiters with live data until the gates in [PILOT-DECISIONS.md](PILOT-DECISIONS.md) pass.

## For the recruiter

1. Obtain access from Erin to the private `erinhadra22/sprout-recruit` repository. Use your own GitHub account; do not share Erin's credentials. Repository access is separate from your app data and service-account connections.
2. Install/sign in to the desktop app containing Codex. Open a local folder for this project. Codex can work with the files in that folder; see [official desktop setup](https://learn.chatgpt.com/docs/app).
3. Ask Codex to clone the private repository using your authorized Git authentication, or download/extract the approved source version and open that folder. A connected GitHub MCP account does not automatically authenticate command-line Git.
4. Send the install prompt below. Complete any Apple developer-tools installation prompts yourself when required. The resulting Sprout app runs independently of Codex after installation; Codex is used for setup, maintenance and troubleshooting.
5. Record your installed version and commit. Use your own local workspace. No other recruiter's contacts or drafts should be included in the repository or installation.

### Install prompt to paste into Codex

> Read README.md, docs/PILOT-DECISIONS.md, docs/CODEX-INSTALL.md and docs/PRODUCTION-READINESS-AUDIT.md. Install the owner-approved Sprout Recruit pilot version on this Mac from this private repository. First check the device, prerequisites, approved commit and release gates. Preserve any existing Sprout workspace and Keychain settings. Do not use a test database as my workspace or send outreach. Build into staging, verify the bundle, and install into my user Applications folder only after the documented gates pass. Open it and verify icon launch, quit/reopen and saved-record persistence. Report the exact version, commit, data path and any blocker. If recovery/onboarding gates remain open, prepare a development preview with disposable data and report the remaining work instead of calling it a pilot install.

## Maintainer procedure

### Preflight

- Check `sw_vers`, `uname -m`, `xcode-select -p`, `xcrun swift --version`, and available macOS SDKs. The first supported architecture is arm64. Do not install Intel/Windows/iPhone builds on the strength of this Mac result.
- Use a reviewed, owner-approved immutable commit or tag and record it with `git rev-parse HEAD`. Inspect local modifications; never discard them to force an update. There is no approved pilot release tag yet.
- Apple Command Line Tools or compatible Xcode provide the Swift compiler and SDK. `xcode-select --install` may require a human download/license step. Do not accept new legal terms on the user's behalf. Do not buy an Apple Developer membership.
- Node.js is only needed to run interface development tests, not to use Sprout Recruit. Discover a supported Node runtime on that installation rather than hardcoding another person's home path.
- Existing installations require a verified workspace backup before replacement. Resolve any saved `legacyWorkspacePath`; the original development `app/Data` workspace must not be moved/deleted or replaced with a fresh database. A fresh repo clone excludes that data.

### Build into staging

Run from the repository root after preflight. These commands compile and verify a development bundle, not a customer distribution release:

```sh
SPROUT_STAGE="$(mktemp -d -t sprout-build)"
SPROUT_OUTPUT="$SPROUT_STAGE/Sprout Recruit.app" zsh app/build.sh
codesign --verify --deep --strict "$SPROUT_STAGE/Sprout Recruit.app"
```

The build script selects a compatible local SDK where known; otherwise it uses `xcrun`. If the compiler/SDK disagree, stop and select a matching installed toolchain. Do not relabel compiler failure as an app-launch defect. For this Mac, the approved public certificate fingerprint is persisted in Git-ignored `app/.local-signing-identity`; the build uses that identity with `--timestamp=none`. The file must contain exactly 40 hex bytes without a newline and is never evaluated. `SPROUT_LOCAL_SIGNING_IDENTITY` explicitly overrides it; `SPROUT_SIGNING_IDENTITY` selects the unchanged distribution branch and ignores it. Never copy/export a private key. A fresh clone does not include the per-Mac selection: identify the approved local certificate and supply its public fingerprint before updating an existing certificate-signed installation. Without any selection the script retains the ad-hoc development fallback, which must not silently replace the installed persistent identity. Verify the same designated requirement before installation, then check existing Messages access after launch. Perform trust validation in the real user context; a tool sandbox may lack access to user Keychain trust. `app/package-release.sh` deliberately requires Developer ID for its production path; `--preview` is a non-notarized development archive and must not be described as a customer installer.

When the user requests validation, run native and web fixture tests against disposable fixtures only, following README. Do not run write tests against the live database. Tests alone do not verify installation, restore or external services.

### Repeatable installer

Run from the repository root using the full, reviewed 40-character commit SHA. A branch name or arbitrary latest main is not an approval. Commit source changes first; the tool refuses dirty checkouts and does not fetch, reset, pull or change branches.

```sh
# Read-only preflight; replace the placeholder with the approved full SHA.
zsh app/install-local.sh install --commit APPROVED_40_CHARACTER_SHA --check

# Build, verify, snapshot any existing workspace, then install.
zsh app/install-local.sh install --commit APPROVED_40_CHARACTER_SHA
```

The installer:

1. Requires the recruiter's own account, Apple Silicon, macOS 26.6.x, an installed Swift toolchain, and every Sprout process quit. It never uses sudo, accepts toolchain licenses, downloads prerequisites, launches the app or terminates processes.
2. Rejects symlinks in installation/workspace paths, parent traversal, unowned endpoints and unexpected private files inside the bundle. It verifies the bundle identifier, executable, arm64 architecture and code signature.
3. Resolves the saved legacy workspace or fresh per-user workspace. Missing saved paths block installation. An original source-adjacent database without a saved preference blocks installation until the existing app has registered its path; it is never silently moved or replaced. `--workspace /absolute/path/SproutRecruit.sqlite` can identify an existing workspace but cannot override a conflicting saved preference.
4. Builds with `SPROUT_OUTPUT` into a unique private staging folder under `~/Applications/.SproutRecruitInstallations/`. The staged executable must explicitly support the existing workspace schema, and existing data gets a verified native recovery snapshot before app replacement. The tool never copies a live WAL database by itself.
5. Uses macOS atomic path exchange to replace an existing app at `~/Applications/Sprout Recruit.app`, then retains the old app as `previous.app`. A failed exchange leaves the old app in place. First installation uses a single rename. A lock prevents overlapping installer invocations. A power loss or force-kill can require supervised recovery from the retained transaction; no automatic data restore is attempted.
6. Writes a private receipt under `~/Library/Application Support/Sprout Recruit Install Receipts/`. It records exact commit, date/time, OS, architecture, workspace path, backup result, version/build and whole-bundle/executable hashes. Receipts and app history stay outside Git and the dedicated workspace folder, and are not automatically pruned. Recovery snapshots use the native recovery root so they also appear in the app's recovery list.

Fresh installs use `~/Library/Application Support/Sprout Recruit/SproutRecruit.sqlite`. Existing registered workspaces retain their original path and path-keyed credentials. The installer does not migrate legacy data or modify connected accounts. Keep using the installed bundle rather than older source/backup copies; inspect any existing Desktop/Dock shortcuts before retargeting them.

The installer prints `installed-awaiting-acceptance`, **not** a claim that the device is ready for recruiting work. No pilot release tag is approved by the existence of this tool.

### Acceptance after installation

- Open `~/Applications/Sprout Recruit.app` through Finder. Verify a visible window, quit/reopen and minimize/icon reopen.
- If startup shows Opening workspace and waits for file access, use Choose this workspace folder and select the exact existing folder displayed. Do not choose a different workspace or disable macOS security protections. Verify quit/reopen afterward; a rebuilt ad-hoc signature can require reconfirmation.
- Complete operator onboarding. With a disposable workspace, save a clearly labeled test record, quit and reopen, and confirm identity, dates/times and persistence. Never leave fictional people mixed with recruiting data.
- Make and restore a recovery snapshot against disposable data. Confirm attachments, drafts, tasks and schema compatibility. Never perform destructive restore acceptance on a live recruiting workspace.
- Record exact receipt path, commit, version/build, OS/architecture, resolved data path and acceptance outcomes in a private local record. Run under a separate standard user and then another recruiter Mac before expanding the supported matrix. No OS account is created automatically.
- If macOS presents a security warning, capture the exact message. Do not disable security protections or strip quarantine automatically. Downloaded unsigned binaries may behave differently from local builds.

### Code rollback

```sh
zsh app/install-local.sh rollback --receipt "/absolute/path/to/Sprout Recruit Install Receipts/TRANSACTION.json"
```

Rollback verifies the receipt belongs to this installation, both retained/current bundle hashes and signatures still match, the app is quit, and the retained app explicitly supports the current workspace schema. It retains the newer bundle as `rolled-back.app` and restores the previous app. **It does not restore or delete workspace records.** If a workspace schema is too new, stop and have the maintainer choose a tested compatible app or supervised snapshot restore. Restoring an older snapshot can lose later edits and requires an explicit, informed decision.

Older app versions without the recovery CLI marker cannot prove schema compatibility and are refused before execution. A successful code rollback does not undo a schema upgrade. Missing files, modified bundles, conflicting paths, stale installer locks or interrupted transactions require review; never delete data or use `git reset --hard` as a repair. An interrupted transaction retains its `prepared` receipt and both bundles; after an exchange, the old bundle may still be named `staged.app` (or the newer rollback bundle `previous.app`) until bookkeeping finishes. An engineer must compare receipt hashes with the actual target before repairing these app-only names.

Installer fixture validation (temporary folders and stubbed macOS commands; no actual installation):

```sh
python3 -B app/Tests/installer_test.py
```

### Update prompt to paste into Codex

> Read the repository's current installation instructions and release notes. Compare my installed commit with the owner-approved pilot release. Show the changes, preserve local source edits, and check schema compatibility. Make and verify a recoverable workspace backup, retain the previous app, then build and install the approved version. Verify reopening and persistence. Do not change my connected accounts or send messages. If backup/restore or migration is not supported for this version, stop before replacing the installed app and report the gap.

Manual updates are intentional. Never silently update to whatever is on main. Code rollback does not reverse a database migration; use a compatible tested backup/restore route, with the user informed of any data since the backup that would be lost. Do not use `git reset --hard` or delete the data folder as a repair.

## Local-first does not mean shared CRM

Each recruiter has a separate local workspace. GitHub distributes code and instructions; it does not synchronize contacts, drafts or notes between recruiters. Shared pipeline synchronization is a separate design decision outside this pilot. External accounts will be individually connected in the next phase; no provider setup is required to use the pilot's local CRM features.

## Support and privacy

Send Launch99 a concise reproduction, app version/commit, OS/architecture and redacted error details. Keep private contact data, correspondence, database backups and tokens out of GitHub issues and commits. Repository source access does not authorize uploading a recruiter's workspace. No automatic telemetry or remote access is enabled by these instructions.

## Recovery and existing-workspace migration

Version 0.5.0 supports schema 1 and adopts legacy schema 0 only after making a verified pre-upgrade snapshot. A future schema is refused. Local snapshots include consistent SQLite data, managed Knowledge/Attachments, file hashes, timestamps, and an inventory of linked external paths. External files and Keychain credentials are not copied. Recovery is local to this Mac; an approved device backup is still needed for loss or damage to the Mac.

Settings → Local data recovery creates snapshots, lists verified recovery points, and selects a snapshot for restoration on the next app launch. Restore retains the complete previous workspace and uses a recovery journal around the folder switch. Snapshots are retained without automatic deletion. A daily snapshot is made on first launch each UTC day, and before bulk imports and schema upgrades. A continuously open session does not schedule a new daily snapshot until the next launch.

A maintainer may copy a legacy workspace into a **new, nonexistent** dedicated folder while all Sprout processes are quit:

```sh
'/path/to/Sprout Recruit.app/Contents/MacOS/SproutRecruit' \
  --migrate-workspace '/absolute/source/SproutRecruit.sqlite' \
  --to '/absolute/new-workspace/SproutRecruit.sqlite'
```

This makes a verified source snapshot, preserves the source, copies managed documents, rewrites only managed path fields, and records record counts/date/time plus a reconnect requirement. It does not switch the app's saved workspace pointer or operational import scripts. Validate the returned destination and coordinate every existing reference before switching. Do not delete the source. The original development workspace remains in place until its operational queue/import references can move together.

The app holds an exclusive workspace lease. Quit it before offline command-line writes, restores, or migration. Read-only SQLite inspection and consistent snapshot copying remain available; an attempted command is never a reason to bypass the lease or retry a message send.

## Opening Erin’s installed app — October 22 verification

Open the existing **Sprout Recruit** shortcut on the Desktop. It resolves to the canonical project app. To quit, use **Sprout Recruit → Quit Sprout Recruit** or Command-Q; open the same Desktop shortcut again to restart. If the app is running without a visible workspace, use **Sprout Recruit → Show Workspace**. If workspace access is requested, choose the exact existing workspace folder shown; Erin’s current records remain in `app/Data`. Do not open a backup bundle. The optimized installation passed Desktop-path launch, normal quit/reopen and Show Workspace checks; a literal Finder double-click was not exercised.

## Next-device acceptance

Use [SECOND-MAC-ACCEPTANCE.md](SECOND-MAC-ACCEPTANCE.md) for exact prerequisites, commands and return evidence. Use standard per-user Application Support paths: temporary or aliased workspace locations remain unsupported pending path-normalization fixes.

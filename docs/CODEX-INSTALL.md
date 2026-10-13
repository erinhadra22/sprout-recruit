# Install and update Sprout Recruit with Codex

Scope: supervised internal Sprout source-build pilot, Apple Silicon Mac. Current first-device baseline is macOS 26.6.2 (25G83). This is the agreed installation design and an engineering setup guide; the pilot recovery/onboarding gates are still unfinished. Do not onboard other recruiters with live data until the gates in [PILOT-DECISIONS.md](PILOT-DECISIONS.md) pass.

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

The build script selects a compatible local SDK where known; otherwise it uses `xcrun`. If the compiler/SDK disagree, stop and select a matching installed toolchain. Do not relabel compiler failure as an app-launch defect. The default local build is ad-hoc signed. `app/package-release.sh` deliberately requires Developer ID for its production path; `--preview` is a non-notarized development archive and must not be described as a customer installer.

When the user requests validation, run native and web fixture tests against disposable fixtures only, following README. Do not run write tests against the live database. Tests alone do not verify installation, restore or external services.

### Install and acceptance

This step must be implemented as a repeatable installation tool before recruiter rollout. Until then a developer should supervise it:

- Quit the existing Sprout app. Preserve the old app bundle and a validated workspace backup. Refuse replacement while the app remains running.
- Copy the verified staged app to a temporary sibling of `~/Applications/Sprout Recruit.app`, check its signature, then rename into place. Never replace the workspace directory. Avoid duplicate app copies and stale Desktop/Dock targets.
- Fresh installs use `~/Library/Application Support/Sprout Recruit/SproutRecruit.sqlite`. Legacy installs retain their saved data path until a separate verified migration. Record the actual resolved path.
- Open the installed bundle through Finder/normal macOS launch. Verify a visible window; quit/reopen; minimize/reopen through its icon; save/reopen a clearly labeled disposable test record; confirm operator attribution and date/time. Do not leave fabricated sample people mixed with recruiting data.
- Verify recovery from the installed version before pilot acceptance. Record commit, version/build, OS/architecture, data path, pre-install backup, prior app location and validation outcome in a local receipt outside Git.
- If macOS presents a security warning, capture the exact message for review. Do not disable security protections or automatically remove quarantine. Downloaded unsigned binaries may behave differently from local builds.

### Update prompt to paste into Codex

> Read the repository's current installation instructions and release notes. Compare my installed commit with the owner-approved pilot release. Show the changes, preserve local source edits, and check schema compatibility. Make and verify a recoverable workspace backup, retain the previous app, then build and install the approved version. Verify reopening and persistence. Do not change my connected accounts or send messages. If backup/restore or migration is not supported for this version, stop before replacing the installed app and report the gap.

Manual updates are intentional. Never silently update to whatever is on main. Code rollback does not reverse a database migration; use a compatible tested backup/restore route, with the user informed of any data since the backup that would be lost. Do not use `git reset --hard` or delete the data folder as a repair.

## Local-first does not mean shared CRM

Each recruiter has a separate local workspace. GitHub distributes code and instructions; it does not synchronize contacts, drafts or notes between recruiters. Shared pipeline synchronization is a separate design decision outside this pilot. External accounts will be individually connected in the next phase; no provider setup is required to use the pilot's local CRM features.

## Support and privacy

Send Launch99 a concise reproduction, app version/commit, OS/architecture and redacted error details. Keep private contact data, correspondence, database backups and tokens out of GitHub issues and commits. Repository source access does not authorize uploading a recruiter's workspace. No automatic telemetry or remote access is enabled by these instructions.

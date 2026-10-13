# Sprout Recruit

Sprout Recruit is a prerelease local Mac recruiting workspace built with Swift, SQLite, and a bundled WebKit interface. It is being prepared for a small internal Sprout recruiter pilot. The first target is the owner’s Apple Silicon Mac. Installations will build locally from this private source repository with Codex assistance; this is not a notarized binary release.

Start with [pilot decisions](docs/PILOT-DECISIONS.md) and [Codex installation/update instructions](docs/CODEX-INSTALL.md). The guide includes copy-and-paste prompts and current readiness gates. Private repository: [erinhadra22/sprout-recruit](https://github.com/erinhadra22/sprout-recruit). Erin owns the repository and manages developer access.

## Development

Use a Mac with Xcode or matching Command Line Tools, a compatible macOS SDK, and Node.js for the interface fixture tests. This source checkout contains no customer workspace or provider credentials.

```sh
cd app
SPROUT_SDK="$(xcrun --sdk macosx --show-sdk-path)" SPROUT_ARCH="$(uname -m)" zsh build.sh
zsh test.sh
node --test Tests/*.test.cjs
open 'Sprout Recruit.app'
```

`SPROUT_SDK` selects an installed SDK compatible with the local Swift compiler. `SPROUT_ARCH` selects the build architecture. Native tests use disposable fixtures and execute a copy of the binary outside the application bundle. Do not point tests at a real workspace database.

The desktop application does not require Node.js on an end user's Mac. Node.js is used only by development tests. Optional communications require separately configured provider accounts and an internet connection. Opening a composer does not prove a sent message or delivery.

## Release readiness

See [the production readiness audit](docs/PRODUCTION-READINESS-AUDIT.md) for completed fixes, validation evidence, release gates, and product decisions. The internal pilot uses local source builds without Apple Developer enrollment. Keep user data separate from source/app files and complete recovery, onboarding and install/upgrade validation before other recruiters use real data. Developer ID/notarization is deferred for this source-build pilot; it remains the recommended future path for downloadable prebuilt binaries. Do not describe an ad-hoc preview as a notarized release.

The optional [iPhone call pilot](app/MobilePilot/README.md) is separate from the desktop release. Its device calling and recording acceptance remain unverified. Generate its excluded Xcode project locally with `python3 app/MobilePilot/create_project.py`; signing configuration stays local.

## Repository privacy

The repository uses a strict source allowlist. Customer databases, exports, backups, recordings, private handoff evidence, credentials, signing keys, generated application bundles, and developer configuration must remain outside Git. Review `git diff --cached` before every first publication or bulk addition; never use `git add -f` to bypass these rules.

Credentials belong in the operating system's Keychain. Do not paste secrets into source, issues, screenshots, logs, or commit messages. Keep fixtures fictional and use reserved example domains and phone numbers.

No open-source license has been selected. Public repository visibility and redistribution terms require the owner's decision.

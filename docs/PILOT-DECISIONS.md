# Sprout internal pilot decisions

Confirmed by Erin on October 13, 2026. These decisions supersede the open Q1–Q8 choices in the initial production audit. They set scope; they do not establish that pending features are implemented.

| Topic | Confirmed direction |
|---|---|
| Audience | Small internal Sprout pilot, distributed to other recruiters in the agency. One operator and local workspace per installation. |
| Version 1 | CRM, CSV imports, tasks, notes, reviewed drafts and tested recovery. Unfinished AI execution, background inbox sync, automated sourcing and iPhone recording stay outside the pilot release. |
| First supported device | Erin's current Apple Silicon Mac, observed arm64 with macOS 26.6.2 (25G83). Expand the supported matrix only after testing additional devices. The build's minimum OS setting is not a support guarantee. |
| Installation | Private repository source, built locally with Codex assistance. No Apple Developer enrollment or App Store distribution in this phase. |
| Integrations | Next phase. Each recruiter owns and authorizes their own accounts. The app should provide connection, disconnect, status and setup instructions. Use native in-app account setup where providers support it; do not assume all providers offer OAuth. Secrets stay in Keychain and never in Git. |
| Backups | Erin requested a recommendation; portable backups are not a current requirement. Proposed local recovery policy below remains a recommendation. |
| Updates/support | Manual, reviewed updates with install/support instructions in the repository, assisted by Codex. For this pilot, these are local source rebuilds; prebuilt signed updates require revisiting signing. No background updater or telemetry is authorized. |
| Ownership | Private repository owned by Erin (connected account erinhadra22), proposed name sprout-recruit. Erin will share it with primary developer Launch99 Agency. No invitation sent and no account identity guessed. |

## October 22 communication trial direction

Erin will try Manus for email draft outbox and inbox management, and for texting through a newly dedicated agent phone number instead of iMessage. This supersedes the earlier iMessage direction for the texting trial. The dedicated number is user-reported; no Manus connection, message delivery, inbox coverage or app integration has been verified by this decision. This does not establish a change to the separate iPhone calling/recording requirements.

Keep this trial separate from the local app installation acceptance. Before relying on Manus communication results in Sprout Recruit, establish a reviewed handoff/import format with account and recipient identity, channel, message/thread identifiers, timestamps, body and honest draft/sent/failed/unknown status. Verify inbox coverage and how received replies pause follow-ups. Confirm what data leaves the device and how access is disconnected. Outreach remains draft-only until Erin authorizes the specific send; reconcile uncertain results before any retry.

See [AI and inbox connection workstream](../app/workstreams/AI-AND-INBOX-CONNECTION.md) for the bounded trial acceptance needs. No new provider purchase, account permission, deployment or scheduled outreach is authorized by this direction alone.

## Installation recommendation

Use a reviewed commit or release tag, not an arbitrary latest main-branch snapshot. Codex opens the local checkout, reads [CODEX-INSTALL.md](CODEX-INSTALL.md), checks prerequisites, builds into a staging folder, and installs the verified bundle into `~/Applications/Sprout Recruit.app`. New workspaces live in `~/Library/Application Support/Sprout Recruit/`; source code and app replacement must not overwrite that folder.

Copying the repository alone does not install a runnable app. A local Swift build is required. No paid Apple Developer account is needed for the existing ad-hoc local build command. This is a supervised source-build pilot; it does not provide Developer ID identity or notarization for a downloaded binary. Apple documents Developer ID specifically for apps outside the App Store: [Developer ID](https://developer.apple.com/developer-id/). If macOS blocks an app, report the exact warning and resolve it through supported controls; do not disable Gatekeeper or automatically strip quarantine.

## Recommended backup policy for the pilot

Implement an automatic local recovery snapshot before each app/database upgrade and bulk import, plus once per day when the app is used. Recommend retaining seven daily snapshots and the last three pre-upgrade snapshots; rotate only after a newer backup passes validation. These counts are proposed defaults, not an implemented schedule or approved deletion policy.

Snapshots should contain a consistent SQLite backup plus managed attachments and a version/checksum manifest. Use SQLite's backup API; do not copy just a live WAL database file. Restore into staging, validate, retain the current workspace, then switch atomically. Test a real restore with disposable data before recruiting data is entrusted to the pilot. Keychain credentials are not exported; users reconnect their own accounts when necessary. Referenced external files must be included or explicitly identified as missing dependencies.

Keep recovery data outside the Git checkout and app bundle, with private filesystem permissions. Use the agency's approved device encryption and an encrypted off-device backup for device loss. Local snapshots alone cannot recover a lost Mac. A built-in portable backup/export feature can follow later; tested local recovery remains a pilot requirement.

## Required next engineering work

1. Implement and verify local snapshots, restore and versioned migration; protect the existing development workspace and path-keyed credentials.
2. Add recruiter onboarding and remove hardcoded operator attribution. Keep Sprout company branding for this internal pilot.
3. Hide or clearly disable unfinished integrations in the pilot interface.
4. Build a repeatable preflight/install/update/rollback tool based on the Codex guide; preserve a previous app bundle and workspace backup.
5. Exercise a fresh installation under a separate standard macOS user on the supported device, then a second recruiter device before expanding rollout.
6. Publish a reviewed pilot tag only after these gates pass; record exact commit, build, OS and recovery result in each installation receipt.

The source audit fixes already completed remain recorded in [PRODUCTION-READINESS-AUDIT.md](PRODUCTION-READINESS-AUDIT.md). No customer-ready release is claimed.

## October 13 implementation follow-through

The 0.5.0 candidate implements first-run recruiter/company/timezone setup, local verified recovery with managed attachments, schema-0 adoption and future-schema refusal, offline migration tooling, manual source installation and code rollback guards. It also adds task edit/reschedule/reopen, CSV busy handling, and a read-only historical-evidence audit. Unfinished integration controls are hidden or rejected in the pilot interface. Test and device acceptance results are recorded in PRODUCTION-READINESS-AUDIT.md.

Implemented retention is preserve-all: automatic pruning and portable exports are not enabled. The proposed seven-daily/three-upgrade policy above remains unapproved. Erin will manage Launch99 access tomorrow; no invitation or scheduled reminder was created.

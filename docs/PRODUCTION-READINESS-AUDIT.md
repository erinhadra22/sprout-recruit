# October 22 additional current-Mac acceptance

Recovery, installer transaction and disposable GUI checks are recorded in `handoff/evidence/mac-acceptance-20261022/README.md`. These add real permission failures, managed attachment migration/restore, real atomic installer update/rollback, onboarding and moved-bundle persistence. Temporary path aliases remain an unresolved restriction; full keyboard/VoiceOver and device-environment acceptance remain open. See [second-Mac checklist](SECOND-MAC-ACCEPTANCE.md) before rollout.

# October 22 installation follow-through

Optimized 0.5.0 (10) is now installed. Desktop shortcut path launch, normal quit/reopen and Show Workspace were verified with computer control. A literal Finder double-click was not exercised. Fresh optimized native checks, 50 web tests and 20 installer fixtures passed. All live record bodies matched before/after; database integrity OK. Evidence: `handoff/evidence/optimized-install-20261022/`. This supersedes the pending optimized-install statements in the historical October 13 audit below. Separate-user/device and realistic failure acceptance remain open. Manus email/text trial direction is recorded in PILOT-DECISIONS.md.

# Sprout Recruit production readiness audit

Updated October 13, 2026. Current implementation: **0.5.0 (10)**. The earlier installed launch audit used 0.4.8 (9).

**Assessment: implementation and fixture checks support continued supervised internal-pilot testing. Current-Mac launch and disposable-workspace recovery were observed; separate-user and second-device installation acceptance remain pending; this is not approval for broad rollout.** A passing test suite does not establish that every possible bug is absent.

## Confirmed pilot scope

Small internal Sprout recruiter pilot, one local operator per installation, current Apple Silicon Mac first. Version 1 covers contacts, CSV imports, tasks, notes, reviewed drafts and local recovery. Installation and manual updates use reviewed private-repository source with Codex assistance. No Apple Developer enrollment or prebuilt signed distribution is planned in this phase. Individual account connections, AI execution, background inbox sync, provider SMS and iPhone recording remain phase two.

See [confirmed decisions](PILOT-DECISIONS.md) and [Codex installation guide](CODEX-INSTALL.md). The repository owner will arrange developer access separately. Product decisions are settled; device acceptance remains required.

## Scope and evidence

Source review covered startup/WebKit, SQLite store, CSV imports, contacts/tasks/drafts, timestamps, workflows, communications and Keychain, AI outbox, local knowledge, performance reporting, Web interface, build/signing, the iPhone pilot boundary, and repository privacy. Independent bounded reviewers checked data reliability, UI behavior, and security/release controls. This was a code and regression audit, not a completed formal Codex Security scan or a penetration test.

| Check | Current evidence and limit |
|---|---|
| Native implementation | 0.5.0 (10) optimized build and all native suites passed on the development Apple Silicon Mac. |
| Native regression coverage | Storage, imports, context, AI outbox, performance, workflows, communications, external correspondence, provider receipts, onboarding, tasks, history review, schema upgrades and recovery fixtures passed. Provider fixtures do not send messages. |
| Recovery fixtures | SQLite WAL backup, attachment/checksum validation, corrupt snapshots, interrupted restore/restart, migration, malformed JSON and unsupported-schema handling passed using disposable workspaces. Actual power failure or a physically full disk was not tested. |
| Interface fixtures | **49 passed, 0 failed**, including onboarding, timezone display, linked-draft task editing, CSV interruption guards and recovery/history presentation. |
| Installer fixtures | **20 passed** for source-install/update/rollback protections. These are fixtures, not a completed installation on a separate user or device. |
| Current Desktop launch | 0.5.0 debug build launched from the Desktop icon and reopened after quitting. Selecting its existing workspace through the native folder picker resolved an observed file-open wait. The Mac locked before final optimized-bundle installation and icon verification; that final check is pending. |
| Post-launch workspace readback | SQLite integrity OK; 1,048 contacts, 50 drafts and 50 tasks retained. Ordered stored-record hashes are identical before/after schema 0 to 1 adoption. No contact, draft or activity record was rewritten. |
| Historical review | Read-only audit of a copy of the live workspace found **138 findings: 50 missing creation timestamps and 88 missing activity recording timestamps**. No suspected legacy-noon or reply-hold findings were reported. No timestamps or reply states were rewritten. |
| External services | No live provider send, call, recording, inbox synchronization or account connection was validated in this work. |
| Source publication | This report accompanies the 0.5.0 source candidate. Check [Desktop checks](https://github.com/erinhadra22/sprout-recruit/actions) for the exact candidate commit; local test evidence does not substitute for that commit’s remote result. Private handoff receipts record the publication readback. |

Counts describe the stated evidence snapshots. Historical recording time cannot be recovered from an occurrence date, import time or modification time without an exact source. The history audit requests evidence review; zero findings for a check are not proof of delivery, source accuracy or absence of every defect.

## Fixes applied automatically

| Area | Change and validation limit | Source |
|---|---|---|
| Launch and reopening | Desktop shortcut resolves directly to the canonical app. Startup now shows a window before background database initialization, with a native picker for the existing workspace folder. Metadata validation uses POSIX file information; bundled-page checks canonicalize symlink paths to avoid a blank page. Show Workspace restores minimized windows. Debug icon launch and quit/reopen were observed; final optimized icon check is pending while the Mac is locked. | `app/Sources/main.swift` |
| Blank display recovery | A stopped WebKit process or failed page load now presents Reload/Quit recovery instead of leaving an unexplained blank window. Recovery code compiled; forced WebKit-crash UI was not exercised. | `app/Sources/main.swift` |
| Installed data location | Fresh installations use per-user Application Support. Existing local workspaces retain their current path through a saved pointer; a missing saved workspace fails clearly instead of silently creating an empty one. Legacy data has not been migrated. | `app/Sources/WorkspaceLocation.swift` |
| Imported contact timestamps | Imported profiles now show first Added to Sprout and Last imported with date/time. Removed the false fixed October 2 source date. Reimports preserve the original first-import timestamp. | `app/Web/csv-import.js; app/Sources/GenericCSVImport.swift` |
| Actual activity timestamps | New manual call/message confirmations capture local date/time and persist a UTC instant. Provider timestamps are retained. Date-only evidence stays date-only; it is no longer assigned an invented noon. AI result drafts receive a creation timestamp. | `app/Sources/CommunicationsStore.swift; Workflows.swift; AIJobs.swift` |
| Form behavior | Action buttons explicitly do not submit forms. Dirty dialogs require an explicit discard; workspace search cannot replace an open dialog. Successful saves still close normally. | `app/Web/app.js` |
| Import correctness and size | Recheck preview token under the database write lock; reject stale previews. Validate regular-file size before a bounded 30 MB CSV read. | `app/Sources/GenericCSVImport.swift` |
| Reply handling | New verified inbound correspondence pauses active sequences enrolled before that reply and their pending drafts, atomically and without replay duplication. Historical replies predating enrollment do not pause newer sequences. | `app/Sources/ExternalMessages.swift` |
| Draft send gates | Communication attempts carry exact draft identity; changed, paused or rejected drafts are rejected at review and again before handoff. Editing text cannot clear a reply pause. | `app/Sources/CommunicationsStore.swift; Store.swift` |
| Sent record consistency | An exact confirmed send or verified delivery marks the matching draft sent and updates its review task wording. Task completion remains manual. Sent tasks have no resend action; sent draft IDs cannot be overwritten as drafts. Provider accepted/queued remains unconfirmed. | `app/Sources/CommunicationsStore.swift; app/Web/app.js` |
| Local privacy | Exact bundled page required at the native message bridge. Newly created data directories are private and managed database files use owner-only permissions. Existing Keychain behavior retained. | `app/Sources/main.swift; Store.swift` |
| Build and repository hygiene | Configurable SDK/architecture/output path; clean release packaging with explicit preview mode and mandatory Developer ID/notary profile for release. Source-only Git allowlist and macOS CI added. Real contact test names and operator email fixtures replaced. | `app/build.sh; app/package-release.sh; .gitignore; .github/workflows/ci.yml` |

## Additional pilot work implemented in 0.5.0

| Area | Implementation | Verification and remaining limit |
|---|---|---|
| Local recovery | Consistent SQLite snapshots, managed attachments/dependency handling, checksums and version manifest; daily-use and pre-change recovery points; Settings create/list/restore controls. Restore validates before replacement, keeps the prior workspace and uses an interrupted-restore journal. | Disposable WAL, corruption, dependency and restart fixtures passed. Native UI create/restore/restart recovered an earlier operator profile in a disposable workspace. No automatic retention deletion is enabled. Local snapshots cannot protect against loss of the Mac. |
| Versioned upgrades | Tested schema 0 to 1 adoption with pre-upgrade protection, unsupported/newer-schema rejection and upgrade recovery guards. This is not a general implementation of future migrations. | Native migration/schema fixtures passed. Each future migration still needs its own fixtures and supported upgrade acceptance. |
| Recruiter onboarding | Fresh empty workspace asks for name, company and valid display timezone. New attribution uses the saved operator; existing identities/preferences and historical records are retained. | Onboarding persistence/validation fixtures and a disposable first-run UI flow passed. Fresh standard-user acceptance remains pending. |
| Pilot feature boundaries | Experimental AI/provider/sequence interfaces are hidden or disabled and unavailable provider execution is blocked at the native bridge. Existing Apple Messages/Phone review handoffs and saved correspondence remain available. | Interface/native fixture coverage passed. Apple handoff itself does not prove a send or completed call. |
| Source install and rollback | Supervised installer performs preflight, stages the reviewed source build, preserves the previous bundle, records an installation receipt and supports app rollback without replacing workspace data. | 20 installer fixtures passed. Actual install/update/rollback acceptance has not yet been completed in this report. |
| Responsive imports | CSV operations use a serial background worker with visible phase/busy state; duplicate submissions, dismissal and navigation are blocked during the operation. | Busy/retry/stale-result interface fixtures passed. This does not promise cancellability after commit or validate every large-data workload. |
| Task corrections | Ordinary tasks support edit, reschedule and reopen. Linked draft-review edits are restricted to due date and priority, preserving exact draft wording and send gates. | Native task and interface fixtures passed, including recurrence/JSON guards. General record revisions and undo remain separate work. |
| Display timezone | Recorded instants use the saved display timezone; date-only history retains an explicit unrecorded-time label. Manual date/time pickers clearly use the device-local timezone. | Interface date-boundary fixtures passed. Existing unknown timestamps are not inferred. |
| Historical evidence review | Settings exposes a read-only audit of creation/recording timestamps and reply-hold evidence, with counts and bounded record references. | Native and interface fixtures passed; the copied-workspace results above remain review findings, not automatic corrections. |

## Remaining work and release gates

| ID | Status / priority | Completion still needed |
|---|---|---|
| R1 | Recovery implemented; device fault acceptance pending | Exercise restore under realistic disk-full and interrupted-power conditions, verify managed dependencies on the target installation, and document recovery behavior. Portable export remains deferred. Retention cleanup awaits an approved policy. |
| R2 | Current-workspace migration deferred | The existing development workspace remains at its preserved location. Coordinate operational references before migrating it; preserve path-dependent Keychain state or provide explicit reconnect instructions. Do not silently move or delete the live store. Migration fixtures are not a completed live migration. |
| R3 | Upgrade framework implemented | Complete actual install/update/rollback acceptance and retain an exact version/commit/OS receipt. Future schema changes need fresh migration and recovery tests. |
| R4 | Paid signing deferred by pilot scope | Local ad-hoc source builds are the pilot route. Developer ID/notarization/Gatekeeper acceptance is a future gate only if prebuilt binaries are distributed. |
| R5 | Onboarding implemented | Verify first-run setup under a separate standard macOS user, including identity attribution after restart and updates. |
| R6 | Pilot acceptance blocker | Test fresh standard-user install on the supported Mac, then a second recruiter Mac. Cover first launch, quit/reopen, update/rollback, moved app, no network, denied permissions, sleep/wake, long paths and recovery. Do not expand supported OS/architecture claims from the build target alone. |
| R7 | External services: phase two | Each recruiter will connect their own accounts. Native connection/disconnect flows, consent, data-sharing disclosures and real device/provider verification remain unimplemented or unaccepted. No live connection is implied by preserved settings. |
| R8 | Responsiveness improved; scale acceptance pending | Measure import behavior at realistic pilot volumes and memory limits. Keep failure recovery and commit boundaries explicit; small fixtures do not prove a 25,000-contact workload. |
| R9 | Accessibility acceptance pending | Run full keyboard-only and VoiceOver checks, focus restoration/inert-background review, selected-tab semantics and smaller-display acceptance. Empty-focus dialog handling is fixed; this is not a completed accessibility audit. |
| R10 | Historical evidence requires source review | Preserve the 50 missing creation timestamps and 88 missing recording timestamps as unknown unless exact evidence supplies them. No legacy-noon/reply-hold findings appeared in the copied-workspace audit; do not perform speculative repairs. |
| R11 | Ordinary task corrections implemented; broader undo deferred | Saved-search editing, general record revisions, draft version history and archive/undo still need design and implementation before broader use warrants them. Existing draft send/reply safeguards must remain intact. |
| R12 | Manual source installation implemented; operations acceptance pending | Finish installation/support acceptance, define redacted opt-in diagnostics, supported versions and recovery ownership. No background updater or telemetry is authorized. Source sharing/access remains the owner's step. |
| R13 | Source candidate publication verification | Require exact remote tree match and a passing Desktop checks run for the candidate commit before any release tag. Publication receipts are private handoff evidence; no pilot tag is approved merely by a green build. |

## Release sequence and acceptance

1. Publish and verify the current source-only implementation and run CI on its exact commit.
2. Complete actual source install/update/rollback acceptance with a recorded commit, build, OS and recovery result; keep the current live workspace location stable until migration references are coordinated.
3. Exercise a separate standard-user workspace with disposable data before involving another recruiter. Confirm onboarding, tasks, imported timestamps, draft review and recovery after restart.
4. Test on a second recruiter Mac before expanding rollout. Record the supported device/OS matrix explicitly.
5. Complete realistic fault and accessibility checks, resolve or explicitly scope the remaining limitations, and approve a pilot tag only after required acceptance gates pass.
6. Keep external services outside this release. A later prebuilt download additionally requires revisiting signing/notarization and downloaded-app acceptance.

## Build and fixture checks

```sh
cd app
zsh build.sh
zsh test.sh
node --test Tests/*.test.cjs
python3 Tests/installer_test.py
```

Use the [Codex installation guide](CODEX-INSTALL.md) for supervised source-install commands and prerequisites. Copying a repository alone does not install a runnable app. Keep workspace data separate from source and app-bundle replacement.

Preview packaging remains available with `zsh package-release.sh --preview`; its archive is explicitly a local, non-notarized preview. The prepared Developer ID/notary-profile release route is outside this pilot phase. Do not disable operating-system security controls to bypass an installation warning.

## GitHub and data handling

The private repository uses a deny-by-default source allowlist. Application source, fixtures, brand assets, build scripts, CI and sanitized documentation are eligible. Live databases, contact/draft records, imported CSVs, private backups, handoff evidence, account secrets, generated apps and signing material stay outside Git. Packaging must never include a recruiter's workspace.

The candidate must have its own exact tree/content verification and CI result. Consult the commit-specific Desktop checks result and private handoff publication receipt; a previous green run is insufficient.

## Authoritative distribution references

- [Apple: preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution) — distribution configuration and hardened runtime.
- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Developer ID, notarization and acceptance for future binary distribution.
- [GitHub: adding locally hosted code](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github) — source repository publication.

## Learning Loop Update

Recovery, onboarding, upgrade handling, source installation and task corrections now have implementation and fixture evidence. Device installation, realistic failure tests and external integration acceptance are separate gates. Historical missing timestamps remain unknown; no repair was inferred. Application-specific source and test changes do not require a generalized skill revision. Canonical project learning and installation evidence are recorded separately at closeout.

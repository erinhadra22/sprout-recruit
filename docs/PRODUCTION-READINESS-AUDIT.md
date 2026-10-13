# Sprout Recruit production readiness audit

Audit: October 13, 2026 UTC / October 12 evening America/Chicago. Build: 0.4.8 (9).

**Assessment: suitable for continued supervised local testing; not yet ready for distribution to customers.** Desktop icon launch and visible workspace were verified after installation. The report identifies current defects and release gates; a passing test suite cannot establish that every possible bug is absent.

## October 13 pilot scope decision

Erin answered Q1–Q8: internal Sprout recruiters; core CRM/import/task/note/reviewed-draft scope; current Mac first; Codex-assisted local source builds without Apple Developer enrollment; individual external accounts in phase two; manual updates; Erin-owned private repository with Launch99 as the intended developer. See [confirmed decisions and backup recommendation](PILOT-DECISIONS.md) and [installation guide](CODEX-INSTALL.md). No pilot release is approved yet. The signed-binary gate below applies to a future prebuilt distribution, while recovery/onboarding and installation acceptance remain required for this pilot.

## Scope and evidence

Source review covered startup/WebKit, SQLite store, CSV imports, contacts/tasks/drafts, timestamps, workflows, communications and Keychain, AI outbox, local knowledge, performance reporting, Web interface, build/signing, the iPhone pilot boundary, and repository privacy. Independent bounded reviewers checked data reliability, UI behavior, and security/release controls. This was a code and regression audit, not a completed formal Codex Security scan or a penetration test.

| Check | Result |
|---|---|
| Native build | Passed on the development Apple Silicon Mac |
| Native fixture suites | Passed: storage, imports, context, AI outbox, performance, workflows, communications, external correspondence and Telnyx receipt fixtures |
| Web fixture tests | 34 passed, 0 failed |
| Additional draft guards | Passed on a disposable database: editing keeps reply hold; sent ID cannot become an unsent draft |
| Data-location fixtures | Passed fresh-install location, moved-app stability, legacy-path preservation and missing-workspace failure |
| Desktop icon | Double-click in Finder started the exact installed executable; visible workspace read back; reopening after minimize inspected |
| Live data readback | SQLite integrity OK; 1,048 contacts, 50 unsent drafts, 50 exact contact links and one open review task per draft |
| Imported profile | Added to Sprout and Last imported date/time visible; linked unsent draft activity timestamp visible |
| Live providers | No message/call/network send performed; actual delivery/recording/inbox sync remains untested |
| Release packaging | Preview ZIP built and inspected: 48 archive members, zero private data files; release correctly refuses without Developer ID |
| GitHub | Private repository created: erinhadra22/sprout-recruit; source publication tracked separately from pilot readiness |

The current 1,048 contacts exclude the 24 fictional sample records removed by separate earlier work. This audit did not delete contacts or send outreach. Earlier 1,072 counts describe that older sample-containing snapshot. Opening a profile can update its ordinary last-viewed value.

## Fixes applied automatically

| Area | Change and validation limit | Source |
|---|---|---|
| Launch and reopening | Desktop shortcut now resolves directly to the current app. Added Show Workspace and reopening support that restores minimized windows. Double-click launch was observed with the correct executable and a visible workspace. | `app/Sources/main.swift` |
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

## Work still required

| ID | Priority | Area | Required completion | Owner / decision |
|---|---|---|---|---|
| R1 | Release blocker | Backup and restore | User backup is JSON export; no complete restore UI or tested attachment recovery. Implement a versioned archive, validation in a staging location, pre-restore SQLite backup, atomic swap and interrupted-restore recovery. Test older/newer schemas, corrupt archives, disk-full and rollback. | Engineering; recommended local snapshot defaults are in PILOT-DECISIONS.md. Portable export is deferred. |
| R2 | Release blocker for current-workspace migration | Legacy data and Keychain migration | The working development CRM remains in app/Data. Fresh installs are stable, but a guided migration for existing installs must copy SQLite consistently, preserve knowledge references, validate counts/integrity, and preserve or reconnect path-keyed Telnyx credentials. Do not delete the old workspace until recovery is proven. | Engineering; migration is substantive work, not a one-line path change. |
| R3 | Release blocker | Versioned upgrades | The store has seed/context migrations but no general ordered database migration/rollback framework. Establish supported upgrade paths, pre-upgrade backups, downgrade/newer-schema rejection and interrupted-upgrade tests. | Engineering. |
| R4 | Deferred for source-build pilot | Signed and notarized binary distribution | The installed audit build is ad-hoc signed. Release script is prepared but Developer ID signing, hardened-runtime acceptance, notarization, stapling and Gatekeeper acceptance on another Mac remain unperformed. | Future binary distribution; no Apple Developer enrollment in this phase. |
| R5 | Release blocker for other people | Operator and company onboarding | Fresh workspace settings, activity authors and several UI defaults still assume the original operator/company. Add first-run name/company/time-zone setup and use it for future attribution without rewriting historical records. | Engineering; internal Sprout onboarding confirmed. |
| R6 | Release blocker | Clean-device acceptance | Test fresh standard-user install, first launch, quit/reopen, upgrade, app move, backup/restore, no network, denied permissions, sleep/wake, long paths, read-only disk and disk-full. Test every supported Mac architecture and OS. Current UI acceptance is on the development Mac only. | Engineering/QA; current Apple Silicon Mac first. |
| R7 | Feature release gate | AI, calling and inbox integrations | AI remains a local request outbox; summary generation has no execution adapter. iPhone recording is a separate unverified pilot. Gmail/Messages background sync and after-hours service are not implemented. Require actual device/provider acceptance or hide unavailable capabilities from v1. | Deferred to next phase; hide unfinished capabilities from pilot. |
| R8 | Before broader pilot | Import responsiveness and scale | CSV parsing/planning still runs synchronously on the UI callback. Move expensive work to a serial background worker with progress/cancel and measure supported limits. Do not extrapolate small-fixture timing to a 25,000-contact workload. | Engineering. |
| R9 | Before broader pilot | Accessibility and window sizes | Visible focus and basic dialog trapping exist; complete inert-background/focus restoration, keyboard-only and VoiceOver checks, selected tab semantics and smaller display behavior. Current window minimum is 1080x720. | Engineering; target supports macOS accessibility expectations. |
| R10 | Data review | Historical timestamp/reply evidence | Previously fabricated noon timestamps and older imported replies were not silently rewritten or replayed. Identify affected records, distinguish occurrence time from recording time, and prepare a reviewable correction plan. | Engineering; user review only if evidence cannot determine truth. |
| R11 | Before broader pilot | User recovery for ordinary edits | Task edit/reschedule/reopen, saved-search editing, record revisions, draft history and archive/undo are incomplete. Prioritize safe reversal and visible audit history for destructive or mistaken edits. | Engineering; prioritize with release scope. |
| R12 | Release operations | Update, support and privacy process | Implement manual Codex-assisted source rebuilds for approved versions. Define support/crash-report handling with opt-in and redaction; retention/deletion/export policy, supported OS/architectures, third-party notices, and a release rollback owner. No telemetry or updater was silently installed. | Manual updates confirmed; implement local recovery and redacted support process. |
| R13 | Repository created | GitHub repository | Erin created private erinhadra22/sprout-recruit. MCP readback verified ownership, private visibility and write access. Publish the source-only tracked tree and verify every blob against the local snapshot. | Erin owns repository and will manage Launch99 access. |

## Q1–Q8 resolved by Erin

The original questions are answered in [PILOT-DECISIONS.md](PILOT-DECISIONS.md). Do not ask them again as open choices. Local snapshot retention is a proposed recommendation; portable backup is deferred. Launch99 access remains Erin's sharing step, with exact GitHub identity not yet supplied.

## Release sequence and acceptance

1. Follow the confirmed internal pilot scope and current-Mac target. Keep incomplete integrations visibly unavailable.
2. Finish backup/restore, versioned migration and operator onboarding; preserve the current live workspace and Keychain connection during migration.
3. Run a release candidate from the source-only repository. CI must build/test cleanly on a fresh runner. Scan dependencies and the final tracked file set for secrets and private data.
4. Package only the app bundle. Never ship app/Data, imported CSVs, correspondence, source company documents, local handoff evidence, credentials or private backups.
5. For this pilot, build the reviewed source locally using the Codex install guide and verify installation/upgrade under a fresh standard-user account. For a later prebuilt download, configure Developer ID/notarization and test Gatekeeper acceptance separately.
6. Pilot with a small consenting group using disposable/noncritical data first; record launch failures, data recovery outcomes, UI issues and provider behavior. Approve broader release only after the blocking items pass.

## Build and package commands

```sh
cd app
zsh build.sh
zsh test.sh
node --test Tests/*.test.cjs
zsh package-release.sh --preview
# Production requires configured Developer ID and notarytool Keychain profile:
SPROUT_SIGNING_IDENTITY="Developer ID Application: …" SPROUT_NOTARY_PROFILE="…" zsh package-release.sh
```

Preview archives are explicitly labeled LOCAL-PREVIEW-NOT-NOTARIZED. Signing/notarization removes an installation trust barrier; it does not resolve the product/data recovery gates above. Fresh installed workspaces use `~/Library/Application Support/Sprout Recruit`; the current development workspace remains at its preserved existing path.

## GitHub handling

The local repository uses a deny-by-default source allowlist. Application source, fixtures, brand assets, build scripts, CI and this sanitized report are eligible. Live databases, backups, handoff records, benchmark identities, account files, generated apps and signing material are excluded. Current source is 75 source/configuration files plus this report. The private remote now exists under erinhadra22/sprout-recruit. Source publication is verified against the exact local tracked tree; private workspace data remains outside Git.

## Authoritative distribution references

- [Apple: preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution) — distribution configuration and hardened runtime.
- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Developer ID, notarization and acceptance.
- [GitHub: adding locally hosted code](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github) — source repository publication.

## Learning Loop Update

Durable findings: restricted-shell Launch Services errors were not valid evidence that the executable was missing; actual icon launch must be checked through the normal desktop. Imported records have a separate UI renderer that must share timestamp behavior. Project instructions and local audit evidence are retained; generalized skill changes are deferred because these are application-specific fixes. Canonical learning capture is recorded separately at closeout.

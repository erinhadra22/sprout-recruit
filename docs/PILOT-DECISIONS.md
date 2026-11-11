# November 4, 2026 — reporting, meeting booking and sourcing exclusions

Erin selected a Monday **09:00 America/Chicago** aggregate report to **cody@sprouthomes.com** for the prior Monday–Sunday week: calls/emails/texts made, appointments booked, meetings held and explicitly linked conversation-to-booking conversion. The report may disclose incomplete capture; it must not infer conversations from task completion or attendance from scheduled events.

Changing status to **Meeting scheduled** must open a reviewed Calendar booking form. Internal attendees start with **erin@sprouthomes.com** and **cody@sprouthomes.com**, are manually editable in Settings, and default to **60 minutes**; the agent is the variable attendee. User acceptance includes adding another internal attendee in Settings and verifying the next booking picks it up. Calendar consent and invitations remain explicit user actions.

Erin named **Monument Brokerage**, approved **Monument Realty** as an additional brokerage name, and named **Choose Charlie** / **Choose Charlie team** (Austin) for sourcing exclusions. Monument exclusion applies across markets. Live settings `sourcing-rules` are authoritative; these dated decisions do not replace the saved profile, current affiliations or other eligibility evidence.

Implementation, installation and external-service acceptance are tracked separately in `handoff/WORKSPACE-IMPROVEMENTS-2026-11-04.md`.

# October 30, 2026 — meeting responses installed in 0.9.1

Version **0.9.1 (21)** is installed and signed with the existing identity. Calendar `METHOD:REPLY` and exact attendee `PARTSTAT` evidence now produce **Meeting response — Accepted / Declined / Tentative**, with a separate meeting-response counter. Accepted responses pause eligible outreach tasks, unsent drafts, sequences and queued texts. Declined/tentative responses do not trigger that acceptance pause; malformed calendar evidence is held for review. Subject wording alone does not classify an RSVP.

Misty Bills' saved acceptance (`1a183a85ece4aac2`) was corrected through a validated native command after a consistent backup. Original body, message/provider IDs and review-task ID were preserved. Gmail now counts 1 human reply and 1 meeting response. Policy task `4F2C09C9-2E26-4E6A-A466-D44369FAA3D0` is complete. Full native tests and 160 web tests passed; a disposable database repair also passed before the live correction. The installed app launched; Gmail and Messages are Ready with 1,048 contacts and SQLite integrity ok. Final contact-card navigation was blocked by computer-control errors; the specific label is covered by web tests and saved native readback, not a live card screenshot.

Prior 0.8.3 app and consistent database rollback snapshots remain under `handoff/evidence/2026-10-30-meeting-response/`. Existing 0.9.0 sourcing source is included and preserved; its provider-access, scheduler and separate-device gates remain. No outreach was sent. Read `validation.json`, `native-tests.log`, `live-readback.json` and `provider-calendar-evidence.json` in that evidence folder.

# October 30, 2026 — controlled Gmail reply and follow-up pause passed

The isolated native Gmail test passed with real incoming message `1a18d92434a91d59`, from `nickt3744@gmail.com` to `erin@sprouthomes.com` at `2026-10-30T16:08:43Z`. The saved body and subject exactly match provider evidence, including the actual blank lines, unhyphenated wording and sender signature; the originally requested template is not claimed as the received text.

The reply paused the existing Check-in task, unsent Email draft and sequence, and created one linked Review task. Repeat scanning and a reopened native readback retained one copy of that provider message and one reply-review task. A distinct user Sent reply was also imported as history. No app/harness send, communication attempt or outbox job was created; candidate status remained unchanged.

This used the production OAuth/API/coordinator/Store code with a separate fixture database and the existing workspace Keychain authorization. Credentials were not copied or exported. The fixture's new-only floor was `2026-10-29T19:59:45.712Z`; the main workspace's approved 60-day history scope was not replaced. The actual activity renderer displays `externalMessages` directly alongside local activities, so no duplicate email row in `activities` is required.

The coordinator verified the actual candidate Activity log with Email received and Follow-ups paused for review, plus the paused follow-up and draft in Tasks. Acceptance task `CC6800D3-EA82-4B54-84A1-C793A30C9447` is completed with saved readback at `2026-10-30T16:14:34Z`; the main app was relaunched afterward. Separate Medium-priority Review `4F2C09C9-2E26-4E6A-A466-D44369FAA3D0`, due November 2, asks whether a distinct Meeting response label should pause outreach or only log the RSVP. That policy issue does not block this genuine-reply acceptance. Open-app-only sync, native OS notifications and broader distribution remain limited or unverified. Evidence under `handoff/evidence/2026-10-29-gmail-sync/live-reply-test/` includes `acceptance-audit.json`, `provider-native-comparison.json`, replay/reopened readbacks, `activity-log.png`, `paused-followup.png` and `completed-task-readback.json`.

# October 29, 2026 — native Gmail connected; initial 60-day history complete

**0.8.3 (19) is installed, and native Gmail is connected to `erin@sprouthomes.com`.** Erin saved the Desktop client secret through the native secure field and completed Google consent. The approved **Last 60 days** scan is enabled from `2026-08-30T19:22:08.071Z`; initial backfill and history catch-up completed successfully. A later automatic poll remained Ready with unchanged records and `newReplyCount=0`. The intermittent HTTP 403 during backfill recovered; its error and restore task cleared after successful completion.

The scan added **13 correspondence records: 7 Sent copies, 4 automatic notices and 2 classified responses**. One classified response is an Outlook meeting acceptance and must not be counted as a freeform reply. Independent provider read confirmed Batya Porter's genuine reply (`1a0e2f45027241f2`) against her exact saved email. All 13 imports match unique saved candidate identities; all 95 existing Sent records remain unchanged, with no duplicate provider IDs or open Gmail review keys. The 28 held messages have body-free review evidence: 26 unsupported envelopes and 2 conflicts with previously saved evidence.

At this October 29 checkpoint, automatic notices did not pause follow-ups and one existing Check-in was held for identity review. Batya had no earlier follow-up to pause; the separate October 30 controlled test above now supplies that native pause evidence. Setup task `33344F08-7F3C-4465-93DE-4E8523C19964` was completed with saved-state readback. The meeting-response classification gap remains separate.

Native checks and 126 web tests passed for this build. Credentials remain in the workspace's Keychain; the agent did not inspect or export their values. Current acceptance evidence is in `handoff/evidence/2026-10-29-gmail-sync/live-history/`, including `readonly-acceptance-audit.json`, `provider-reply-verification.json` and `task-closeout-readback.json`. Earlier missing-secret and blank-window checkpoints remain historical evidence. Public distribution and closed-app synchronization are still separate gates.

# October 29 — local signing approved and update verified

Erin approved a dedicated persistent local Code Signing identity and its fresh RSA-2048 private key in the login Keychain. Sprout Recruit Local Signing uses SHA-256 certificate signatures, Code Signing-only EKU and CA=false; public SHA-1 is `1C4DC815738647B595C992A6BE03D37D397FF7D5`. The private key was not exported. Erin separately approved **Code Signing-only Always Trust for this certificate in the login Keychain**. Other trust purposes, System Roots, Apple Developer enrollment and public-distribution scope remain unchanged. Public metadata and the scoped trust readback are under `handoff/evidence/2026-10-29-gmail-sync/local-signing/`.

Two different disposable builds passed strict verification with the same certificate-based designated requirement. The installed0.8.1 (17) app renders 1,048 candidates and Settings → Integrations. Following the initial user FDA grant to signed 0.8, the signed 0.8.1 update retained fresh Messages access without another grant. This is a verified local update on Erin's Mac, not a promise for certificate renewal or another device. Verification must use the real user Keychain context; a tool sandbox without that access can report a misleading trust failure. Full native 0.8.1 checks and strict verification passed; previous 120 web fixtures cover unchanged web resources, and 22 inert signing-selection fixtures passed.

The idle coordinator contact-decoding defect is fixed and startup diagnostics added. The earlier0.8 blank window recovered before the update, so its exact cause remains unproven. At that earlier 0.8.1 checkpoint Gmail was disconnected. The current 0.8.3 connection and completed history scan are recorded above; controlled live follow-up pause acceptance passed October 30.

Identity Approval `A190F0E6-5139-422E-93A2-773C9A38B14A`, narrow-trust Approval `55496F83-7C75-479E-AA59-2C329454E3E1` and signed-app access Review `CF5785D0-54B3-462B-9BE0-14F3D495F2CC` are completed/read back. Renewal Review `B0AB265D-01B6-466A-A3C9-5C415C8EEECE` is saved and open, due **September 29, 2027**, before certificate expiry **October 29, 2027 at 10:10:33 AM CDT**. No signing prompt or missing attention card remains. None of these actions authorizes outreach.

`SPROUT_LOCAL_SIGNING_IDENTITY` selects the public certificate SHA-1. When both signing environment values are empty, `app/build.sh` can read the Git-ignored `app/.local-signing-identity` file: exactly 40 hex bytes without a newline, never evaluated. This Mac's public selection is persisted. Explicit local/distribution environment selections override the file, conflicting selections fail, and malformed files fail rather than falling back to ad hoc. The local branch uses `--timestamp=none` and preserves pilot runtime behavior; DeveloperID packaging remains separate. See [installation procedure](CODEX-INSTALL.md) and [verified acceptance](../handoff/evidence/2026-10-29-gmail-sync/local-signing/0.8.1/acceptance-readback.json).

# October 28 — bulk prior-contact check and manual-outcome correction

Erin said Helen Abrams had not been contacted and asked the agent to verify history before asking her to confirm an outcome. She authorized a bulk check of open/overdue-task contacts using about60 days of Messages/email history, conditional on avoiding individual contact-by-contact work. The check used bulk provider metadata and exact saved phone/email joins. This is separate from her new-reply-only automatic-sync decision. Counts establish history presence, not recruiting purpose, delivery, or completion of follow-up/review tasks. Manual outcome questions should be reserved for genuinely unavailable or ambiguous source evidence. No new send is authorized.

# October 28 — automatic Messages reply sync

Erin requested automatic Messages replies in candidate activity with follow-up pauses and chose **only replies received after enabling sync**. The 0.7.0 implementation is opt-in, local and candidate-phone filtered, running while Sprout is open. It preserves actual provider GUIDs, creates reply-review tasks, pauses eligible sequence/outbox work and leaves recruiting status unchanged. Shared-number matches require identity review rather than guessed attribution. Pausing and resuming retain the original coverage floor.

Full Disk Access is a separate, broad macOS permission; Erin manually enabled it. The installed 0.7.0 build passed the full native suite and 98 web tests, then real new-SMS reply acceptance on October 29: exact sender/body/GUID imported once, sequence and unsent draft paused, one review task, older reply excluded, and no duplicate after scan/restart. No new outbound test was sent. The main workspace was restored with 1,048 contacts and Ready coverage from `2026-10-29T05:01:46.360Z`; test data stayed isolated. This acceptance does not establish actual iMessage sending, closed-app operation, native OS notifications or another-Mac setup. See `handoff/IMESSAGE-WORKBENCH-2026-10-28.md` and `handoff/evidence/2026-10-29-messages-sync/reply-acceptance-validation.json`.

# Sprout internal pilot decisions

Baseline confirmed by Erin on October 13, 2026, with the October 28 messaging amendments recorded below. These decisions supersede the open Q1–Q8 choices in the initial production audit. Decisions set scope; observed implementation and acceptance are stated separately.

| Topic | Confirmed direction |
|---|---|
| Audience | Small internal Sprout pilot, distributed to other recruiters in the agency. One operator and local workspace per installation. |
| Version 1 | CRM, CSV imports, tasks, notes, reviewed drafts and tested recovery. The October 28 increment adds reviewed Apple Messages queueing and a controlled SMS acceptance test. Unfinished AI execution, background inbox sync, automated sourcing and iPhone recording stay outside this increment. |
| First supported device | Erin's current Apple Silicon Mac, observed arm64 with macOS 26.6.2 (25G83). Expand the supported matrix only after testing additional devices. The build's minimum OS setting is not a support guarantee. |
| Installation | Private repository source, built locally with Codex assistance. No Apple Developer enrollment or App Store distribution in this phase. |
| Integrations | Apple Messages local connection is implemented for the internal pilot; broader integrations remain next phase. Each recruiter owns and authorizes their own accounts. Connection, disconnect, service selection and status must be explicit. Use native in-app setup where providers support it; do not assume all providers offer OAuth. Secrets stay in Keychain and never in Git. |
| Backups | Erin requested a recommendation; portable backups are not a current requirement. Proposed local recovery policy below remains a recommendation. |
| Updates/support | Manual, reviewed updates with install/support instructions in the repository, assisted by Codex. For this pilot, these are local source rebuilds; prebuilt signed updates require revisiting signing. No background updater or telemetry is authorized. |
| Ownership | Private repository owned by Erin (connected account erinhadra22), proposed name sprout-recruit. Erin will share it with primary developer Launch99 Agency. No invitation sent and no account identity guessed. |

## October 28 messaging decision and observed acceptance

Erin selected sending from her existing iMessage identity for the first messaging release, accepting Mac permissions and limitations. This supersedes the October 22 dedicated-number texting choice for this release and leaves the separate email trial unchanged. The broader roadmap is in [the October 28 PRD](../handoff/PRODUCT-PRD-2026-10-28.md); internal-pilot distribution rules remain in effect.

She separately authorized one exact test to `+15122229460`, with SMS through Messages acceptable, and manually enabled Sprout Recruit → Messages Automation. Version 0.6.3 (14) submitted that SMS from the isolated acceptance workspace at `2026-10-28T19:26:18Z`; exact outbound Messages history and background/global-popup behavior were verified. Controlled SMS acceptance has now passed: Erin confirmed receipt from the expected sender, and independent Messages readback verified the incoming reply “Hey there” from `+15122229460` at `2026-10-28T19:42:05Z`. Native job `4ad665af-e655-4493-a4b9-0febec5d4fb1` is now `user_confirmed_sent`, reconciled through the supported command with one dispatch attempt; no additional message or provider delivery/read receipt is implied. Task `C18398D0-A110-49E5-91AA-8938D9C6FAE4` is completed with saved-state readback at `2026-10-28T19:56:13Z`. See [the implementation handoff](../handoff/IMESSAGE-WORKBENCH-2026-10-28.md) and [the exact authorization](../handoff/evidence/2026-10-28-imessage-live-test/authorization.json).

The former destination `+15129092505` was revoked as a recipient; it was observed as the default sender in Messages settings. The expected sender is now user-confirmed; that evidence is distinct from an outbound history label of `me`. One test authorization is not approval for prospect outreach or a retry. The main live workspace has a separately verified iMessage connection and no outbox jobs from this test.

The account and selected service are frozen for each authorized job. SMS requires an explicit choice; old clients and jobs default to iMessage, and changing service holds outstanding jobs. Messages still chooses its sending phone/email alias. RCS sending and automatic delivery/read receipts are not supported. The October 28 reply was verified through the connected Messages tool. Version 0.7.0 now supports opt-in new incoming iMessage/SMS/RCS reply capture; real SMS capture and pause/restart acceptance passed on October 29. An actual iMessage send and setup on another Mac remain untested.

## October 22 communication trial (historical)

On October 22, Erin selected a Manus trial for email draft outbox/inbox management and texting through a dedicated agent number. The October 28 decision above replaces that texting selection for the first app release. No Manus connection, inbox coverage or Sprout app integration has been verified. The separate iPhone calling/recording requirements are unchanged.

Keep this trial separate from the local app installation acceptance. Before relying on Manus communication results in Sprout Recruit, establish a reviewed handoff/import format with account and recipient identity, channel, message/thread identifiers, timestamps, body and honest draft/sent/failed/unknown status. Verify inbox coverage and how received replies pause follow-ups. Confirm what data leaves the device and how access is disconnected. Outreach remains draft-only until Erin authorizes the specific send; reconcile uncertain results before any retry.

See [AI and inbox connection workstream](../app/workstreams/AI-AND-INBOX-CONNECTION.md) for the bounded trial acceptance needs. No new provider purchase, account permission, deployment or scheduled outreach is authorized by this direction alone.

## Installation recommendation

Use a reviewed commit or release tag, not an arbitrary latest main-branch snapshot. Codex opens the local checkout, reads [CODEX-INSTALL.md](CODEX-INSTALL.md), checks prerequisites, builds into a staging folder, and installs the verified bundle into `~/Applications/Sprout Recruit.app`. New workspaces live in `~/Library/Application Support/Sprout Recruit/`; source code and app replacement must not overwrite that folder.

Copying the repository alone does not install a runnable app. A local Swift build is required. No paid Apple Developer account is needed for the approved local certificate signing workflow; each installation must establish and validate its own identity and permissions. This is a supervised source-build pilot; it does not provide Developer ID identity or notarization for a downloaded binary. Apple documents Developer ID specifically for apps outside the App Store: [Developer ID](https://developer.apple.com/developer-id/). If macOS blocks an app, report the exact warning and resolve it through supported controls; do not disable Gatekeeper or automatically strip quarantine.

## Recommended backup policy for the pilot

Implement an automatic local recovery snapshot before each app/database upgrade and bulk import, plus once per day when the app is used. Recommend retaining seven daily snapshots and the last three pre-upgrade snapshots; rotate only after a newer backup passes validation. These counts are proposed defaults, not an implemented schedule or approved deletion policy.

Snapshots should contain a consistent SQLite backup plus managed attachments and a version/checksum manifest. Use SQLite's backup API; do not copy just a live WAL database file. Restore into staging, validate, retain the current workspace, then switch atomically. Test a real restore with disposable data before recruiting data is entrusted to the pilot. Keychain credentials are not exported; users reconnect their own accounts when necessary. Referenced external files must be included or explicitly identified as missing dependencies.

Keep recovery data outside the Git checkout and app bundle, with private filesystem permissions. Use the agency's approved device encryption and an encrypted off-device backup for device loss. Local snapshots alone cannot recover a lost Mac. A built-in portable backup/export feature can follow later; tested local recovery remains a pilot requirement.

## Implementation checklist and remaining gates

1. Implemented: local snapshots, restore and versioned migration with disposable validation; retain the separate-user/device acceptance gate.
2. Implemented: recruiter onboarding and configurable operator attribution, retaining Sprout branding for this internal pilot.
3. Ongoing: expose verified capabilities and clearly disable unfinished integrations. Apple Messages has an explicit local connection/service selection and accepted new-reply capture. Native Gmail is connected with completed initial history; controlled live Gmail follow-up pause acceptance passed October 30.
4. Implemented: source preflight/install/update/rollback tooling and retained prior bundle/workspace backups. Continue using its safeguards for each update.
5. Open: exercise a fresh installation under a separate standard macOS user on the supported device, then a second recruiter device before expanding rollout.
6. Open: publish a reviewed pilot tag only after the distribution gates pass; record exact commit, build, OS and recovery result in each installation receipt.

The source audit fixes already completed remain recorded in [PRODUCTION-READINESS-AUDIT.md](PRODUCTION-READINESS-AUDIT.md). No customer-ready release is claimed.

## October 13 implementation follow-through

The 0.5.0 candidate implements first-run recruiter/company/timezone setup, local verified recovery with managed attachments, schema-0 adoption and future-schema refusal, offline migration tooling, manual source installation and code rollback guards. It also adds task edit/reschedule/reopen, CSV busy handling, and a read-only historical-evidence audit. Unfinished integration controls are hidden or rejected in the pilot interface. Test and device acceptance results are recorded in PRODUCTION-READINESS-AUDIT.md.

Implemented retention is preserve-all: automatic pruning and portable exports are not enabled. The proposed seven-daily/three-upgrade policy above remains unapproved. Erin will manage Launch99 access tomorrow; no invitation or scheduled reminder was created.


## October 28 implementation checkpoint: 0.6.3 (14)

Installed version 0.6.3 (14) passes the full native suite and 80 web tests. Final task-action resources were installed, the bundle re-signed and the live GUI verified. It includes the reviewed text workbench/outbox, service freezing, account-discovery compatibility, contact lifecycle activity templates and imported-message reporting. The initial 0.6.0 checkpoint passed 77 tests and had no live send; that earlier status is superseded by the single controlled SMS observation above. Main recruiting records remain separate from the test: 1,048 contacts, 50 drafts, zero live outbox jobs, and a verified iMessage connection.

A normal Launch Services relaunch resolved a startup stall seen in a different launch context. No recovery implementation or data was changed, and the cause of that launch-context difference remains unconfirmed. This remains a supervised internal source-build pilot: controlled SMS acceptance passed, while actual iMessage sending and broader distribution gates remain open; automatic new-SMS reply acceptance subsequently passed on October 29.

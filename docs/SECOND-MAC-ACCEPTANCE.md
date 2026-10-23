# Second Mac installation acceptance

Prepared October 22, 2026. This is a supervised acceptance run using fictional data. It does not approve a release or establish live communications. Follow [CODEX-INSTALL.md](CODEX-INSTALL.md) and [PILOT-DECISIONS.md](PILOT-DECISIONS.md).

## Before scheduling the session

1. Erin or the maintainer must review and publish the intended source changes to the private repository, then supply the **full 40-character approved candidate commit SHA**. The local checkout contained uncommitted changes when this checklist was prepared; installing the existing remote main is not evidence that those changes were tested. No approved pilot tag is asserted here. Acceptance may use an approved candidate commit before a pilot tag is approved.
2. Erin grants the recruiter's own GitHub account access to `erinhadra22/sprout-recruit`. The recruiter accepts the invitation and authenticates Git on that Mac. Do not share Erin's credentials. Connector access alone does not authenticate terminal Git.
3. Use an Apple Silicon Mac (`arm64`) with **macOS 26.6.x**, the installer's current enforced range. Record the exact version/build. Stop on Intel or another OS version for a support review; do not bypass the check or upgrade macOS merely to force acceptance.
4. Use the recruiter's normal **standard macOS user**, without sudo. Install Codex and Apple Command Line Tools or compatible Xcode. The user handles Apple download/license prompts. `/usr/bin/python3`, Git, Swift and the macOS SDK must work. Node is optional for development tests and not needed to run the app. No paid Apple Developer enrollment is required for this local source build.
5. Use a fresh account/workspace containing no recruiting data for this acceptance. Do not transfer Erin's database, snapshots, attachments, preferences or Keychain items. If Sprout already has real data in this account, stop and arrange an isolated standard-user acceptance session; do not reset that workspace.

## Install with Codex

Run these read-only prerequisite checks:

```sh
sw_vers
uname -m
xcode-select -p
xcrun swift --version
xcrun --sdk macosx --show-sdk-path
/usr/bin/python3 --version
git --version
```

Clone into a new local folder. The following placeholder must be replaced with the approved candidate SHA before running the checkout/install commands:

```sh
mkdir -p "$HOME/Developer"
cd "$HOME/Developer"
git clone https://github.com/erinhadra22/sprout-recruit.git sprout-recruit-acceptance
cd sprout-recruit-acceptance
git checkout --detach APPROVED_40_CHARACTER_SHA
git rev-parse HEAD
git status --short
```

Read the instructions in that checked-out version. Confirm the SHA matches exactly and the checkout is clean. If the folder already exists, inspect it rather than overwrite it. Quit every Sprout app/window in this account. Then run:

```sh
zsh app/install-local.sh install --commit APPROVED_40_CHARACTER_SHA --check
zsh app/install-local.sh install --commit APPROVED_40_CHARACTER_SHA
```

Save the output and exact receipt path. The first command is read-only; the second builds and installs. Expected installation status is `installed-awaiting-acceptance`. Do not call that device acceptance. The installer should identify `~/Applications/Sprout Recruit.app` and a fresh workspace at `~/Library/Application Support/Sprout Recruit/SproutRecruit.sqlite`. Investigate an unexpected path before opening the app. Never use another person's absolute home path.

**Known unresolved path-alias restriction:** use the normal per-user Application Support workspace for this acceptance. Do not place it under `/tmp`, `/private/tmp` or another aliased workspace path. Real CLI migration through a temporary-path alias can fail to rewrite managed file references; restore-journal workspace identity can also differ between path spellings. The installer safely rejects a workspace-path mismatch. This is an unresolved engineering restriction, not a fixed bug or permission to override that refusal. A disposable acceptance workspace means fictional data in the fresh standard user's normal workspace, not a temporary-path substitute.

## Run the visible workflow

Mark each item PASS, FAIL or NOT RUN, with the observed result and local date/time.

1. In Finder, double-click `~/Applications/Sprout Recruit.app`. Complete onboarding with the tester's identity, Sprout company and intended timezone. Confirm the fresh workspace is empty and contains no Erin records. Record any macOS file-access or security prompt verbatim. If access is requested, select only the exact workspace folder displayed.
2. Create a clearly fictional contact named `ACCEPTANCE TEST — fictional`, a note with a distinctive phrase, an unsent draft and a task with a date/time. Import a tiny fictional CSV through the mapping/review screen and replay it to check that duplicates are handled visibly. Use no real recipient addresses or routable phone numbers, and send nothing.
3. Add a small local test document through the supported managed document/attachment flow. Record its filename and checksum. Record the contact, note, draft body, task status/date/time and item counts as the recovery baseline.
4. Save, quit with Command-Q and reopen by Finder double-click. Verify the exact saved content and timezone display. Minimize and reopen from the Dock, close the workspace window and choose **Sprout Recruit → Show Workspace**, and repeat normal quit/reopen. Create a Desktop alias to the installed app if desired and test it. Confirm shortcuts resolve to the installed bundle, not a staging/backup app.
5. In **Settings → Local data recovery**, create a snapshot and confirm it appears as verified. Record its path and time. Change the fictional note, draft and task; select the baseline snapshot for restore and follow the quit/reopen instructions. Verify that baseline content, the managed document checksum and task date/status return. Confirm the pre-restore workspace was retained. External linked files and Keychain credentials are not included in snapshots; document any linked dependency separately.
6. With the app quit, temporarily move only the installed app bundle to a clearly named folder under the user's Applications folder using Finder. Open that exact moved bundle and verify it resolves to the same workspace and saved records. Quit and return the bundle to `~/Applications/Sprout Recruit.app`; reopen and recheck the shortcut. Perform this before update/rollback, which expect the standard install path. Never move the workspace as part of this check.
7. Have the user temporarily disconnect networking, reopen the app, edit/save a fictional note and reopen again. Confirm local work persists. Reconnect networking afterward. Separately, have the user sleep and wake the Mac with the saved workspace open, then inspect and save another fictional edit. Record actual observations; fixtures do not substitute for these device checks.
8. Use the keyboard to navigate the sidebar, contact form, draft/task dialog and recovery controls. Check Tab/Shift-Tab focus, Escape dismissal, accessible labels with VoiceOver, and a larger display/text setting. Record inaccessible controls or clipped content. Do not mark accessibility passed from visual appearance alone.

## Update and code rollback

The maintainer must provide **two reviewed compatible candidate commits** to test a real version update: the installed baseline and a later approved candidate. A reinstall of the same commit exercises replacement but is not a version-update test. If two candidates are unavailable, record update/rollback acceptance as pending.

1. Save fictional records and quit. Inspect `git status --short`; preserve any edits. In the clean acceptance checkout, fetch authorized source and check out the approved later full SHA. Record both old and new SHAs.
2. Run the following with the later approved SHA:

```sh
zsh app/install-local.sh install --commit APPROVED_UPDATE_40_CHARACTER_SHA --check
zsh app/install-local.sh install --commit APPROVED_UPDATE_40_CHARACTER_SHA
```

3. Save the **update** receipt path and verified backup result. Open the app from Finder and compare all baseline records and managed document checksums. Quit before rollback.
4. Use that exact update receipt, not the original first-install receipt:

```sh
zsh app/install-local.sh rollback --receipt "/absolute/path/to/Sprout Recruit Install Receipts/UPDATE_TRANSACTION.json"
```

5. Open the restored app; confirm its prior version and persistence of records. Code rollback does not revert data or schema. A schema-compatibility refusal is a safe stop, not permission to restore an old database. Record the refusal and have the maintainer choose a compatible route. Reinstall the selected approved candidate afterward only once the rollback result is recorded.

## Failure handling and acceptance limits

Keep the original workspace, recovery snapshot, previous app and receipts. If onboarding, launch, restore or installation fails, stop the affected sequence and capture the exact error, step, version and path. Do not delete data, remove installer locks, rename transaction internals, strip quarantine, disable Gatekeeper, use sudo or reset the repository to repair it. The maintainer should inspect retained transaction hashes and the recovery journal.

Deliberate process interruption and disk-full testing belong in a maintainer-controlled disposable workspace or bounded test volume. Do not fill the Mac's system disk or force-power-off it. Report any such checks not actually performed as pending; results from this Mac's fixtures do not certify the second Mac.

Manus is the selected external email and dedicated-number texting trial. Installing Sprout does not connect Manus, synchronize inboxes, verify delivery or pause follow-ups based on replies. Manus trial/account/handoff acceptance is separate, and no messages are sent during this checklist.

## Evidence to return to Erin

Send a private, redacted acceptance report containing:

- Mac model, `arm64`, exact macOS version/build, standard-user confirmation, and local date/time/timezone.
- Approved baseline and update SHAs, clean-checkout result, Swift/SDK versions, app version/build, installed bundle path and resolved workspace path.
- Initial and update installer output; receipt paths and redacted receipt contents; backup verification result; rollback result and final installed version.
- PASS/FAIL/NOT RUN for each numbered workflow item, including exact saved-content comparisons and test document checksums before/after restart, restore and update/rollback.
- Snapshot path/time, confirmation the pre-restore workspace was retained, and any external file dependencies.
- Exact warning/error text and redacted screenshots for failed steps; no contact databases, real correspondence, credentials or snapshots in GitHub issues or commits.
- Remaining blockers and whether the maintainer approved this device for the internal pilot. Keep the fictional acceptance workspace separate from future production use; arrange a reviewed transition rather than deleting or reseeding a database.

Separate standard-user acceptance on the first Mac remains its own gate if it has not been observed. Second-Mac acceptance expands support only to the exact device/OS combination tested. Publish the pilot tag only after the required gates are reviewed and approved.

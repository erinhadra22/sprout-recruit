# Sprout iPhone call pilot

September 29, 2026. **Source prepared; iPhone build and live calling/recording unverified.** This is a separate native iPhone pilot for the highest-priority requirement: Erin calls a designated person from Sprout, Telnyx records both speakers, and the Mac retrieves correctly associated audio. It does not replace the Mac CRM or claim complete mobile synchronization.

## What is implemented

- A small SwiftUI outgoing dialer, microphone permission, CallKit start/end/mute/hold integration, speaker/earpiece selection and visible audio-route state.
- Exact US test-number validation and one active call. No automated dialing or automatic redial.
- Short-lived Telnyx WebRTC JWT authentication. The default is memory-only; optional retention uses this iPhone's nonsynchronizing Keychain. Disconnect releases the SDK session; Forget removes the saved token. Expired tokens are removed on the next launch. No provider account API key belongs in this app.
- Optional SDK logging, statistics upload and automatic call reports explicitly disabled using the verified 4.2.1 configuration API. Telephone signaling, audio and provider recording still leave the device.
- A local call journal, excluded from device backup, with request/connection/end evidence and SDK UUID plus actual Telnyx session, leg and optional Call Control IDs. Relaunch marks unfinished records ambiguous. It never invents a successful recording, transcript or summary.
- Explicit sharing of the latest call's JSON evidence. No automatic sync or transcript transfer.
- A Mac recording helper that verifies actual session/leg identity before download, refuses mismatched numbers when supplied, checks a nonempty two-channel WAV, and saves a hash/receipt. It never makes calls, deletes media or generates a summary.

Incoming calling and PushKit registration are deliberately outside this outgoing pilot. Incoming calls presented while connected are declined. Do not attach an important incoming number to this test connection. Apple push credentials are not needed for this outgoing-only test; they become prerequisites when adding incoming background calls.

## Build and install

Open `SproutCallPilot.xcodeproj` in a full Xcode installation that supports the connected iPhone's iOS version. Select the **SproutCallPilot** scheme, the iPhone, your signing team, and a bundle identifier that team can sign. Trust the Mac, enable Developer Mode when iOS requires it, resolve package dependencies, and run. A Personal Team may be sufficient for a temporary outgoing device test, subject to Apple's signing restrictions; durable installation/distribution and later push capabilities require a suitable developer configuration.

The project pins Telnyx SDK **4.2.1**, commit `b466eb161e348a50c45da0842acd84972e52f2f2`. It links the package product `telnyx-webrtc-ios`, whose Swift module is `TelnyxRTC`. Transitive package resolution must be captured from Xcode's generated `Package.resolved` after the first successful resolve; it was not fabricated here.

`python3 create_project.py` regenerates the included project and shared scheme deterministically. It does not download dependencies, build, install or access Telnyx. Set signing after regeneration; the generator intentionally contains no personal team ID or credential.

This Mac currently selects Command Line Tools, not full Xcode. An iOS SDK, `xcodebuild`, device installation and CallKit runtime testing are not available through that setup. **Swift syntax checks are not an iPhone build.** The local model checks explicitly select the existing macOS 26.5 SDK because the default 27 SDK is newer than the installed Swift compiler.

## Provider preparation for the authorized test

Use a dedicated test Credential Connection with an attached Outbound Voice Profile. Configure direct outbound PSTN dialing; leave call parking off for this first path. Set a small spending limit and only the needed destination permissions. Configure **WAV**, recording both speakers on **two channels**, restricted to the test caller number or this dedicated profile. Avoid accidentally enabling recording for unrelated connections sharing a profile.

Use Erin's existing number as outbound identity only after Telnyx accepts its verification and permitted use. This does not port that number or route its incoming calls/SMS into Sprout. Keep the current carrier intact. No number purchase, verification call or port has been performed by this pilot.

Create an appropriately scoped telephony credential/session JWT using the provider's authenticated setup process. Paste the short-lived JWT directly into the iPhone app's secure field. Do not put credentials in source, screenshots, chat, build settings, command arguments or the evidence export. Check current account restrictions, balance and caller-ID eligibility before the first call.

The two in-app confirmations mean the designated tester is ready and provider recording is configured. They do not verify those external facts. Recording status stays **Unverified** even after a successful connection. This is a consented pilot, not a final jurisdiction-aware recording policy.

## Retrieve the recording on the Mac

1. After the call, use **Share call evidence** and save the JSON locally as `call-evidence.json` in a private folder outside the source tree. Check that a Telnyx session or leg identifier was actually supplied.
2. Locate that specific recording in Telnyx. Use its recording UUID; do not guess it from the SDK call UUID.
3. Run the helper from this folder, substituting the exact recording ID and your chosen private local paths:

   ```sh
   python3 fetch_recording.py --recording-id RECORDING_UUID --evidence /absolute/private/path/call-evidence.json --output-dir /absolute/private/path/test-recording
   ```

4. Enter the account API key at the hidden prompt **on this Mac**. It is used only for the metadata request. The subsequent signed media request does not carry that account key. Neither the key nor signed URL is saved. A failed or ambiguous download is not retried automatically.
5. The helper requires matching Telnyx session or leg identity and a two-channel WAV. It writes a restrictive-permission audio file and receipt. It leaves provider retention unchanged. If this SIP flow cannot supply matching identifiers or the recording API does not expose the asset, stop and resolve the mapping; do not fall back to matching by name or phone alone.
6. Listen to each channel. Two channels alone do not prove both speakers are audible. No automatic transcript or custom summary exists in this pilot; those remain a subsequent pipeline milestone after recorded audio passes.

The helper supports standard PCM WAV accepted by Python's `wave` module and a 100 MiB pilot limit. Unsupported encoding, missing WAV, absent identifiers, failed authentication and partial outputs are explicit failure paths. A partially saved file requires inspection before another attempt into a fresh directory.

## Live acceptance record

Record each result as pass, fail or not run, with timestamp and call/recording IDs. All are **not run** at source handoff.

| Test | Required evidence |
|---|---|
| Real iPhone build | Resolved dependency lockfile, Xcode version, iOS version, signing and launch result |
| Outgoing call | Designated recipient answers; displayed caller ID checked; exactly one provider call |
| Both-speaker recording | Matching session/leg IDs; downloaded WAV and receipt; both tracks heard distinctly |
| Simple script | Erin: “Sprout pilot, speaker one, Tuesday at ten.” Tester: “Speaker two, Thursday at two.” Check actual recorded words |
| Call lifecycle | Cancel before answer, recipient hangup, local hangup, no answer and failure leave accurate outcomes |
| Audio behavior | Earpiece, speaker, headset/Bluetooth, mute and system hold checked; route labels reflect actual audio |
| Background | Lock screen and background after connection; sound and call ending remain correct |
| Connectivity | Wi-Fi/cellular transition and connection loss recorded honestly; no silent redial |
| Relaunch | Unfinished call shown as uncertain; no fabricated successful completion |
| Recording failure | Missing asset, wrong identifiers, mono/empty file and duplicate download cannot pass |
| Next milestone | Local transcript, custom summary and Mac CRM attachment verified against actual audio; follow-up remains unsent |

The complete recording test passes only after the designated recipient and two audible tracks are verified. Source preparation or a simulator screenshot does not satisfy it.

## Local verification and references

Run `zsh check_local.sh` for syntax/plist checks, compiled Foundation model checks, Keychain API type checking and recording-helper fixture checks. These use synthetic fixtures and do not contact Telnyx. Full UIKit/SwiftUI/CallKit/Telnyx linking and runtime behavior need Xcode and an iPhone.

Handoff validation: those local checks passed on September 29. Five Python fixture checks cover identity mismatch, phone mismatch, insecure media URLs and two-channel/truncated WAV validation. Compiled Swift model checks cover token/number guards, idempotent record updates, restart ambiguity without invented connection/hangup times, export and corrupt-file preservation. A second work agent reviewed SDK signatures and connection lifecycle; stale-session callbacks and a disconnected pending start were corrected. Device behavior remains untested.

Implementation was checked against the public official SDK's exact 4.2.1 source, including `TxConfig`, `TxClientDelegate`, `TxClient` and `Call`. In particular, the actual delegate requires `onRemoteCallEnded(callId:reason:)` and `onPushDisabled(success:message:)`; older README examples omit details. Source was inspected in a temporary folder, not vendored into this project.

- [Official SDK release 4.2.1](https://github.com/team-telnyx/telnyx-webrtc-ios/releases/tag/4.2.1)
- [Pinned client configuration source](https://github.com/team-telnyx/telnyx-webrtc-ios/blob/b466eb161e348a50c45da0842acd84972e52f2f2/TelnyxRTC/Telnyx/Models/TxConfig.swift)
- [Pinned delegate source](https://github.com/team-telnyx/telnyx-webrtc-ios/blob/b466eb161e348a50c45da0842acd84972e52f2f2/TelnyxRTC/Telnyx/TxClientDelegate.swift)
- [Call identifiers](https://developers.telnyx.com/docs/development/webrtc/ios-sdk/classes/call), [client/CallKit methods](https://developers.telnyx.com/docs/development/webrtc/ios-sdk/classes/txclient), [dialing and speaker methods](https://developers.telnyx.com/docs/development/webrtc/ios-sdk/classes/txclient-extensions)
- [JWT authentication](https://developers.telnyx.com/docs/voice/webrtc/auth/jwt)
- [Outbound profile recording setup](https://support.telnyx.com/en/articles/4320411-more-about-outbound-voice-profiles)
- [Recording retrieval API](https://developers.telnyx.com/api-reference/call-recordings/retrieve-a-call-recording)

Learning closeout and shared reference registration belong to the coordinating workstream. This pilot makes no skill changes: reusable live-operation guidance should follow an actual successful device test.

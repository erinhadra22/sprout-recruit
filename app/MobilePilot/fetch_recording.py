#!/usr/bin/env python3
"""Read-only Telnyx recording retrieval, explicitly invoked after a designated test call.

No dialing, provisioning, deletion, list-all, transcription, or sending endpoints.
The account key is prompted privately on the Mac and never saved.
"""
import argparse
from datetime import datetime, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave

MAX_AUDIO_BYTES = 100 * 1024 * 1024

class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class HTTPSMediaRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_media_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def validate_media_url(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Provider returned an unsupported media URL; HTTPS without URL credentials is required.")

def verify_association(record, evidence):
    # A recording on another leg can share the same call session. A matching
    # session OR exact leg establishes correlation; an SDK UUID alone cannot.
    matches = []
    for provider_key, local_key in [("call_session_id", "telnyxSessionID"), ("call_leg_id", "telnyxLegID")]:
        observed, expected = record.get(provider_key), evidence.get(local_key)
        if observed and expected and str(observed).lower() == str(expected).lower():
            matches.append(provider_key)
    if not matches:
        raise ValueError("Recording has no matching Telnyx session or leg ID. Do not associate by phone number or SDK UUID alone.")
    for provider_key, local_key in [("from", "from"), ("to", "to")]:
        if record.get(provider_key) and record[provider_key] != evidence.get(local_key):
            raise ValueError("Recording phone numbers differ from the test evidence. Review the provider call legs before proceeding.")
    return matches

def inspect_wav(path):
    with wave.open(str(path), "rb") as audio:
        channels = audio.getnchannels()
        rate = audio.getframerate()
        frames = audio.getnframes()
        if channels != 2 or rate <= 0 or frames <= 0:
            raise ValueError("Downloaded WAV is empty or does not have two channels.")
        if len(audio.readframes(frames)) != frames * channels * audio.getsampwidth():
            raise ValueError("Downloaded WAV is truncated; declared frames are missing.")
        return {"channels": channels, "sample_rate_hz": rate, "frames": frames,
                "duration_seconds": round(frames / rate, 3),
                "speaker_audibility": "unverified-listen-to-both-tracks"}

def retrieve(recording_id, evidence, output_directory, api_key):
    recording_id = str(uuid.UUID(recording_id))
    request = urllib.request.Request(
        f"https://api.telnyx.com/v2/recordings/{recording_id}",
        headers={"Authorization": "Bearer " + api_key, "Accept": "application/json"})
    # Do not forward the account Authorization header to a redirect target.
    with urllib.request.build_opener(NoRedirects()).open(request, timeout=20) as response:
        payload = response.read(1024 * 1024 + 1)
        if len(payload) > 1024 * 1024: raise ValueError("Recording metadata exceeded the expected size.")
    provider_record = json.loads(payload)["data"]
    if not isinstance(provider_record, dict): raise ValueError("Unexpected recording metadata shape.")
    if str(provider_record.get("id", "")).lower() != recording_id:
        raise ValueError("Provider returned an unexpected recording ID.")
    matches = verify_association(provider_record, evidence)
    media_url = provider_record.get("download_urls", {}).get("wav")
    if not media_url: raise ValueError("A WAV download is not available. Configure WAV recording and check processing status.")
    validate_media_url(media_url)
    directory = Path(output_directory).expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    final_audio = directory / (recording_id + ".wav")
    receipt_path = directory / (recording_id + ".json")
    if final_audio.exists() or receipt_path.exists():
        raise ValueError("This recording already has an output file. Inspect it before retrying into a new directory.")
    temporary_path = None
    try:
        # A fresh request intentionally carries NO Telnyx account key to media storage.
        with urllib.request.build_opener(HTTPSMediaRedirects()).open(media_url, timeout=30) as response:
            with tempfile.NamedTemporaryFile(prefix=".recording-", dir=directory, delete=False) as temporary:
                temporary_path = Path(temporary.name)
                byte_count = 0
                while True:
                    chunk = response.read(64 * 1024)
                    if not chunk: break
                    byte_count += len(chunk)
                    if byte_count > MAX_AUDIO_BYTES: raise ValueError("Recording is larger than this pilot's 100 MiB limit.")
                    temporary.write(chunk)
        properties = inspect_wav(temporary_path)
        digest = hashlib.sha256(temporary_path.read_bytes()).hexdigest()
        receipt = {
            "schema_version": 1, "downloaded_at": datetime.now(timezone.utc).isoformat(),
            "sdk_call_id": evidence["id"], "provider_recording_id": recording_id,
            "call_session_id": provider_record.get("call_session_id"),
            "call_leg_id": provider_record.get("call_leg_id"),
            "call_control_id": provider_record.get("call_control_id"),
            "association_verified_by": matches, "sha256": digest, "bytes": byte_count,
            "audio": properties, "status": "downloaded-two-channels-listening-required",
            "provider_deletion": "not-requested", "summary": "not-generated"}
        # Exclusive creation protects previous evidence even during a concurrent retry.
        with final_audio.open("xb") as output, temporary_path.open("rb") as audio:
            os.chmod(final_audio, 0o600)
            while chunk := audio.read(64 * 1024): output.write(chunk)
        with receipt_path.open("x") as output:
            os.chmod(receipt_path, 0o600)
            json.dump(receipt, output, indent=2, sort_keys=True)
            output.write("\n")
        return receipt_path
    finally:
        if temporary_path is not None: temporary_path.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recording-id", required=True)
    parser.add_argument("--evidence", type=Path, required=True, help="JSON exported from the iPhone pilot")
    parser.add_argument("--output-dir", type=Path, required=True, help="Private local audio folder outside source control")
    args = parser.parse_args()
    try:
        evidence = json.loads(args.evidence.read_text())
        # Reject an unusable export before prompting for a secret or contacting Telnyx.
        if not evidence.get("telnyxSessionID") and not evidence.get("telnyxLegID"):
            raise ValueError("iPhone evidence has no provider session/leg ID; finish correlation testing first.")
        uuid.UUID(args.recording_id)
        key = getpass.getpass("Telnyx account API key (Mac only, not saved): ").strip()
        if not key: raise ValueError("No key entered; nothing requested.")
        receipt = retrieve(args.recording_id, evidence, args.output_dir, key)
        print(f"Saved verified two-channel WAV and receipt: {receipt}")
        print("Listen to both tracks to verify both speakers. No transcription, summary, or provider deletion was performed.")
    except (ValueError, KeyError, TypeError, OSError, urllib.error.URLError, wave.Error) as error:
        # Network exceptions can contain signed URLs. Do not print their raw payloads.
        if isinstance(error, urllib.error.HTTPError): print(f"Provider request failed (HTTP {error.code}); no completion claimed.")
        elif isinstance(error, urllib.error.URLError): print("Network request failed; inspect existing output before retrying.")
        elif isinstance(error, (OSError, wave.Error)): print("File or WAV validation failed; no recording test pass claimed. Inspect any partial output before retrying.")
        else: print(str(error))
        raise SystemExit(1)

if __name__ == "__main__": main()

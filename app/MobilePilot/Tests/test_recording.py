import importlib.util
from pathlib import Path
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location("recordings", Path(__file__).parents[1] / "fetch_recording.py")
recordings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recordings)

class RecordingChecks(unittest.TestCase):
    def test_provider_session_match_supports_another_leg(self):
        result = recordings.verify_association({"call_session_id": "ABC", "call_leg_id": "different"}, {"telnyxSessionID": "abc"})
        self.assertEqual(result, ["call_session_id"])

    def test_same_phone_or_sdk_id_is_insufficient(self):
        with self.assertRaises(ValueError):
            recordings.verify_association({"from": "+15125550123", "call_session_id": "other"}, {"from": "+15125550123", "id": "other", "telnyxSessionID": "expected"})

    def test_number_mismatch_is_held_for_review(self):
        with self.assertRaises(ValueError):
            recordings.verify_association({"call_leg_id": "abc", "to": "+15125550124"}, {"telnyxLegID": "abc", "to": "+15125550125"})

    def test_insecure_media_rejected(self):
        for url in ["http://example.test/a.wav", "file:///tmp/audio.wav", "https://user:secret@example.test/a.wav"]:
            with self.assertRaises(ValueError): recordings.validate_media_url(url)

    def test_two_channels_do_not_prove_speakers(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "fixture.wav"
            for channels in [1, 2]:
                with wave.open(str(file), "wb") as audio:
                    audio.setnchannels(channels); audio.setsampwidth(2); audio.setframerate(8000)
                    audio.writeframes(b"\0\0" * 800 * channels)
                if channels == 1:
                    with self.assertRaises(ValueError): recordings.inspect_wav(file)
                else:
                    self.assertEqual(recordings.inspect_wav(file)["speaker_audibility"], "unverified-listen-to-both-tracks")
            file.write_bytes(file.read_bytes()[:-100])
            with self.assertRaises(ValueError): recordings.inspect_wav(file)

if __name__ == "__main__": unittest.main()

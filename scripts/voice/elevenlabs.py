"""ElevenLabs voice provider (TTS)."""

import json
import os
import time
import urllib.request

from common import MEDIA_CACHE


# Default voice — "Rachel" (warm female). Change voice_id for others.
# Browse voices: https://api.elevenlabs.io/v1/voices
DEFAULT_VOICE_ID = "El018FmI047NtSsCfyrY"


def generate(api_key, text):
    """Generate speech via ElevenLabs TTS, save to file, return file path."""
    voice_id = DEFAULT_VOICE_ID
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"

    payload = {
        "text": text,
        "model_id": "eleven_multilingual_v2",
        "voice_settings": {
            "stability": 0.5,
            "similarity_boost": 0.75,
            "style": 0.4,
            "use_speaker_boost": True,
        },
    }

    headers = {
        "xi-api-key": api_key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
        "User-Agent": "curl/8.0",
    }

    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status < 200 or resp.status >= 300:
                print(f"ElevenLabs error ({resp.status})")
                return None

            os.makedirs(MEDIA_CACHE, exist_ok=True)
            fname = f"elevenlabs_{int(time.time())}.mp3"
            dest = os.path.join(MEDIA_CACHE, fname)

            with open(dest, "wb") as f:
                f.write(resp.read())

            print(f"ElevenLabs voice saved: {dest}")
            return dest

    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        print(f"ElevenLabs error ({exc.code}): {raw[:500]}")
        return None

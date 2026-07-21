"""Yunwu.ai voice provider (OpenAI-compatible TTS).

Calls the yunwu.ai Audio Speech API:
    POST https://yunwu.ai/v1/audio/speech

Configure via env vars:
    CLAWDESS_YUNWU_VOICE_MODEL — TTS model (default: tts-1)
    CLAWDESS_YUNWU_VOICE       — voice name (default: alloy)

Docs: https://yunwu.apifox.cn/
"""

import json
import os
import time
import urllib.request

from common import MEDIA_CACHE


SPEECH_URL = os.environ.get("CLAWDESS_YUNWU_VOICE_URL", "https://yunwu.ai/v1/audio/speech")
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_VOICE_MODEL", "tts-1")
DEFAULT_VOICE = os.environ.get("CLAWDESS_YUNWU_VOICE", "alloy")


def generate(api_key, text):
    """Generate speech via yunwu.ai TTS, save to file, return file path."""
    payload = {
        "model": DEFAULT_MODEL,
        "input": text,
        "voice": DEFAULT_VOICE,
    }

    headers = {
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
        "User-Agent": "curl/8.0",
    }

    data = json.dumps(payload).encode()
    req = urllib.request.Request(SPEECH_URL, data=data, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status < 200 or resp.status >= 300:
                print("Yunwu voice error (" + str(resp.status) + ")")
                return None

            os.makedirs(MEDIA_CACHE, exist_ok=True)
            fname = "yunwu_" + str(int(time.time())) + ".mp3"
            dest = os.path.join(MEDIA_CACHE, fname)

            with open(dest, "wb") as f:
                f.write(resp.read())

            print("Yunwu voice saved: " + dest)
            return dest

    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        print("Yunwu voice error (" + str(exc.code) + "): " + raw[:500])
        return None

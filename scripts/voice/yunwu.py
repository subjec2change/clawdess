"""yunwu.ai voice provider (TTS, OpenAI-compatible).

Calls the yunwu.ai audio/speech endpoint:
    POST https://yunwu.ai/v1/audio/speech

Response is raw audio bytes saved to MEDIA_CACHE as an .mp3 file.

Configure via env vars:
    CLAWDESS_YUNWU_TTS_MODEL — TTS model  (default: tts-1)
    CLAWDESS_YUNWU_VOICE     — voice name (default: alloy)

Docs: https://yunwu.apifox.cn/
"""

import json
import os
import time
import urllib.request

from common import MEDIA_CACHE


SPEECH_URL = "https://yunwu.ai/v1/audio/speech"
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_TTS_MODEL", "tts-1")
DEFAULT_VOICE = os.environ.get("CLAWDESS_YUNWU_VOICE", "alloy")


def generate(api_key, text):
    """Generate speech via yunwu.ai TTS, save to file, return file path."""
    payload = {
        "model": DEFAULT_MODEL,
        "input": text,
        "voice": DEFAULT_VOICE,
    }

    headers = {
        "Authorization": f"******",
        "Content-Type": "application/json",
        "User-Agent": "curl/8.0",
    }

    data = json.dumps(payload).encode()
    req = urllib.request.Request(SPEECH_URL, data=data, headers=headers, method="POST")

    print(f"YUNWU TTS submitting: model={DEFAULT_MODEL}, voice={DEFAULT_VOICE}")
    try:
        with urllib.request.urlopen(req) as resp:
            os.makedirs(MEDIA_CACHE, exist_ok=True)
            fname = f"yunwu_{int(time.time())}.mp3"
            dest = os.path.join(MEDIA_CACHE, fname)

            with open(dest, "wb") as f:
                f.write(resp.read())

            print(f"YUNWU voice saved: {dest}")
            return dest

    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        print(f"YUNWU TTS error ({exc.code}): {raw[:500]}")
        return None

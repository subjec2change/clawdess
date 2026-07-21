"""Yunwu voice provider (OpenAI-compatible speech API)."""

import json
import os
import time
import urllib.request

from common import MEDIA_CACHE


TTS_URL = "https://yunwu.ai/v1/audio/speech"
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_TTS_MODEL", "tts-1")
DEFAULT_VOICE = os.environ.get("CLAWDESS_YUNWU_VOICE", "alloy")


def generate(api_key, text):
    """Generate speech via Yunwu TTS, save to MEDIA_CACHE, return file path."""
    payload = {"model": DEFAULT_MODEL, "input": text, "voice": DEFAULT_VOICE}
    headers = {
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
        "User-Agent": "curl/8.0",
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(TTS_URL, data=data, headers=headers, method="POST")

    print(f"YUNWU TTS submit: model={DEFAULT_MODEL}, voice={DEFAULT_VOICE}")
    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status < 200 or resp.status >= 300:
                body = resp.read().decode(errors="ignore")
                print(f"YUNWU TTS error ({resp.status}): {body[:500]}")
                return None

            os.makedirs(MEDIA_CACHE, exist_ok=True)
            fname = f"yunwu_{int(time.time())}.mp3"
            dest = os.path.join(MEDIA_CACHE, fname)

            with open(dest, "wb") as handle:
                handle.write(resp.read())

            print(f"YUNWU voice saved: {dest}")
            return dest

    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        print(f"YUNWU TTS failed ({exc.code}): {raw[:500]}")
        return None
    except Exception as exc:  # noqa: BLE001
        print(f"YUNWU TTS request error: {exc}")
        return None

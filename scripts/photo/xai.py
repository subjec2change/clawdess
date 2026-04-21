"""xAI Grok image generation provider."""

import json
import urllib.request

from common import api_post, MEDIA_CACHE


def generate(api_key, prompt, image_url=None):
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": "grok-imagine-image",
        "prompt": prompt,
        "aspect_ratio": "9:16",
        "image": {
            "url": image_url,
            "type": "image_url",
        }        
    }

    req = urllib.request.Request(
        "https://api.x.ai/v1/images/edits",
        data=json.dumps(payload).encode(),
        headers=headers,
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=120) as resp:
        body = json.loads(resp.read().decode())

    results = body.get("data", [])
    if not results:
        print(f"xAI no results: {json.dumps(body)[:500]}")
        return None

    return results[0].get("url")




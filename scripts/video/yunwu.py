"""Yunwu.ai video provider (OpenAI-compatible image-to-video).

Submits an image-to-video job to yunwu.ai and polls until the video URL
is available.

Configure via env vars:
    CLAWDESS_YUNWU_VIDEO_URL   — override the submit endpoint
    CLAWDESS_YUNWU_VIDEO_MODEL — override the model name

Docs: https://yunwu.apifox.cn/
"""

import os

from common import api_post, poll_for_url


SUBMIT_URL = os.environ.get(
    "CLAWDESS_YUNWU_VIDEO_URL",
    "https://yunwu.ai/v1/videos/generations",
)
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_VIDEO_MODEL", "kling-v2-master")


def generate(api_key, prompt, image_url):
    """Submit image-to-video job to yunwu.ai, poll until ready, return video URL."""
    payload = {
        "model": DEFAULT_MODEL,
        "prompt": prompt,
        "image": {"url": image_url},
    }
    headers = {"Authorization": "Bearer " + api_key, "Content-Type": "application/json"}
    code, body = api_post(SUBMIT_URL, headers, payload)

    video_id = body.get("id") or body.get("request_id")
    if not video_id:
        print("Yunwu video submit failed: " + str(body))
        return None
    print("Yunwu video submitted (" + str(code) + "): id=" + str(video_id))

    poll_url = SUBMIT_URL.rstrip("/") + "/" + str(video_id)
    return poll_for_url(poll_url, {"Authorization": "Bearer " + api_key})

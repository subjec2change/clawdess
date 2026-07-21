"""yunwu.ai video provider (image-to-video, OpenAI-compatible gateway).

Submits an image-to-video generation request to yunwu.ai and polls until the
video URL is ready. Both synchronous and asynchronous (job-id) responses are
handled:

- Sync: response body already contains a ``url`` field → returned immediately.
- Async: response body contains a job/task ID → poll a status endpoint until
  a ``url`` field appears.

Configure via env vars:
    CLAWDESS_YUNWU_VIDEO_URL    — submission endpoint
                                  (default: https://yunwu.ai/v1/video/generations)
    CLAWDESS_YUNWU_VIDEO_MODEL  — model name (default: wan2.1-i2v-14b-720p)

Docs: https://yunwu.apifox.cn/
"""

import os

from common import api_post, extract_url, poll_for_url


VIDEO_URL = os.environ.get(
    "CLAWDESS_YUNWU_VIDEO_URL", "https://yunwu.ai/v1/video/generations"
)
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_VIDEO_MODEL", "wan2.1-i2v-14b-720p")


def generate(api_key, prompt, image_url):
    """Submit image-to-video to yunwu.ai, poll until ready, return video URL."""
    payload = {
        "model": DEFAULT_MODEL,
        "prompt": prompt,
        "image_url": image_url,
        "duration": 5,
    }
    headers = {
        "Authorization": f"******",
        "Content-Type": "application/json",
    }

    print(f"YUNWU video submitting: model={DEFAULT_MODEL}")
    code, body = api_post(VIDEO_URL, headers, payload)

    # Check if a URL is already present in the synchronous response
    found = extract_url(body)
    if found:
        print(f"YUNWU video ready (sync): {found}")
        return found

    # Async: look for a job/task/request ID to poll
    job_id = (
        body.get("id")
        or body.get("task_id")
        or body.get("request_id")
        or body.get("job_id")
    )
    if not job_id:
        print(f"YUNWU video submit failed ({code}): {str(body)[:500]}")
        return None

    print(f"YUNWU video submitted ({code}): job_id={job_id}")
    # Poll a status endpoint — try common patterns used by yunwu-proxied providers
    status_url = f"{VIDEO_URL.rstrip('/')}/{job_id}"
    return poll_for_url(status_url, headers)

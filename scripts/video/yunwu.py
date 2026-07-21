"""Yunwu video provider (OpenAI-compatible gateway)."""

import json
import os

from common import api_post, extract_url, poll_for_url


DEFAULT_URL = os.environ.get("CLAWDESS_YUNWU_VIDEO_URL", "https://yunwu.ai/v1/video/generations")
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_VIDEO_MODEL", "wan2.2-i2v")
DEFAULT_DURATION = int(os.environ.get("CLAWDESS_YUNWU_VIDEO_DURATION", "15"))


def _sync_url_from_body(body):
    """Extract a direct media URL when the endpoint returns synchronously."""
    data = body.get("data")
    if isinstance(data, list) and data:
        url = extract_url(data[0])
        if url:
            return url
    output = body.get("output")
    if isinstance(output, list) and output:
        url = extract_url(output[0])
        if url:
            return url
    return None


def _poll_url_from_body(body, submit_url):
    """Extract polling URL from response, or build one from a request ID."""
    for key in ("poll_url", "status_url", "result_url", "retrieve_url"):
        url = body.get(key)
        if isinstance(url, str) and url.startswith("http"):
            return url
    request_id = body.get("request_id") or body.get("id")
    if request_id:
        return f"{submit_url.rstrip('/')}/{request_id}"
    return None


def generate(api_key, prompt, image_url):
    """Submit image-to-video generation to Yunwu and return the final media URL."""
    payload = {
        "model": DEFAULT_MODEL,
        "prompt": prompt,
        "duration": DEFAULT_DURATION,
        "image_url": image_url,
        "init_image": image_url,
    }
    headers = {
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
        "User-Agent": "curl/8.0",
    }

    print(f"YUNWU video submit: url={DEFAULT_URL}, model={DEFAULT_MODEL}")
    try:
        code, body = api_post(DEFAULT_URL, headers, payload)
    except Exception as exc:  # noqa: BLE001
        print(f"YUNWU video submit request error: {exc}")
        return None
    print(f"YUNWU video submit response ({code}): {json.dumps(body)[:500]}")
    if code < 200 or code >= 300:
        return None

    direct_url = _sync_url_from_body(body)
    if direct_url:
        return direct_url

    poll_url = _poll_url_from_body(body, DEFAULT_URL)
    if not poll_url:
        fallback = extract_url(body)
        if fallback:
            return fallback
        print("YUNWU video submit did not include URL or request ID.")
        return None

    print(f"YUNWU video polling: {poll_url}")
    try:
        return poll_for_url(poll_url, headers)
    except Exception as exc:  # noqa: BLE001
        print(f"YUNWU video poll request error: {exc}")
        return None

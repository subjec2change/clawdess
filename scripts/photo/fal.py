"""FAL photo provider (OpenAI GPT-Image-2 Edit) — async queue."""

import json
import time

from common import api_post, api_get, extract_url


def generate(api_key, prompt, image_url):
    payload = {
        "image_urls": [image_url],
        "prompt": prompt,
        "image_size": "portrait_16_9",
        "quality": "high",
        "num_images": 1,
        "output_format": "png",
    }
    headers = {"Authorization": f"Key {api_key}", "Content-Type": "application/json"}
    code, body = api_post("https://queue.fal.run/openai/gpt-image-2/edit", headers, payload)
    request_id = body.get("request_id")
    if not request_id:
        print(f"FAL submit failed ({code}): {json.dumps(body)[:500]}")
        return None
    print(f"FAL submitted ({code}): request_id={request_id}")

    auth = {"Authorization": f"Key {api_key}"}
    status_url = f"https://queue.fal.run/openai/gpt-image-2/edit/requests/{request_id}/status"
    result_url = f"https://queue.fal.run/openai/gpt-image-2/edit/requests/{request_id}"

    # Poll status until completed
    for i in range(300):
        _, status_body = api_get(status_url, auth)
        status = status_body.get("status", "")
        print(f"FAL poll {i}: status={status}")

        if status == "COMPLETED":
            _, result = api_get(result_url, auth)
            return extract_url(result)
        if status in ("FAILED", "ERROR"):
            print(f"FAL failed: {json.dumps(status_body)[:500]}")
            return None

        time.sleep(5)

    return None

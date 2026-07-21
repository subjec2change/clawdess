"""Yunwu.ai photo provider (OpenAI-compatible image edit).

Calls the yunwu.ai Images Edit API (image-to-image):
    POST https://yunwu.ai/v1/images/edits   (multipart/form-data)

The reference image is uploaded as bytes and the edited result comes back as
a URL or base64 (data[0].b64_json), which we decode to a temp file and hand
back as a file:// URL for common.download_file.

Docs: https://yunwu.apifox.cn/
"""

import base64
import json
import os
import tempfile
import urllib.request
import uuid
from urllib.parse import urlparse
from urllib.request import pathname2url


EDIT_URL = os.environ.get("CLAWDESS_YUNWU_IMAGE_URL", "https://yunwu.ai/v1/images/edits")

DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_IMAGE_MODEL", "gpt-image-1")
DEFAULT_SIZE = os.environ.get("CLAWDESS_YUNWU_IMAGE_SIZE", "1024x1024")
DEFAULT_QUALITY = os.environ.get("CLAWDESS_YUNWU_IMAGE_QUALITY", "high")

_CONTENT_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}


def _load_image(image_ref):
    """Return (bytes, filename, content_type) for a URL, file:// URL, or local path."""
    parsed = urlparse(image_ref)
    if parsed.scheme in {"http", "https"}:
        req = urllib.request.Request(image_ref, headers={"User-Agent": "curl/8.0"})
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
        name = os.path.basename(parsed.path) or "reference.png"
    else:
        path = image_ref[7:] if parsed.scheme == "file" else image_ref
        path = os.path.abspath(os.path.expanduser(path))
        with open(path, "rb") as handle:
            data = handle.read()
        name = os.path.basename(path) or "reference.png"

    ext = os.path.splitext(name)[1].lower()
    content_type = _CONTENT_TYPES.get(ext, "image/png")
    if ext not in _CONTENT_TYPES:
        name = "reference.png"
    return data, name, content_type


def _multipart(fields, image_field, image):
    """Encode form fields + one image file into (body, content_type)."""
    boundary = "----clawdess" + uuid.uuid4().hex
    crlf = b"\r\n"
    parts = []
    for key, value in fields.items():
        parts.append(b"--" + boundary.encode())
        parts.append(("Content-Disposition: form-data; name=\"" + key + "\"").encode())
        parts.append(b"")
        parts.append(str(value).encode())

    data, filename, content_type = image
    parts.append(b"--" + boundary.encode())
    parts.append(
        ("Content-Disposition: form-data; name=\"" + image_field + "\"; filename=\"" + filename + "\"").encode()
    )
    parts.append(("Content-Type: " + content_type).encode())
    parts.append(b"")
    parts.append(data)

    parts.append(b"--" + boundary.encode() + b"--")
    parts.append(b"")
    body = crlf.join(parts)
    return body, "multipart/form-data; boundary=" + boundary


def generate(api_key, prompt, image_url):
    """Edit image_url with prompt via yunwu.ai; return a URL or file:// URL to the result."""
    try:
        image = _load_image(image_url)
    except Exception as exc:  # noqa: BLE001
        print("Yunwu: failed to load reference image: " + str(exc))
        return None

    fields = {
        "model": DEFAULT_MODEL,
        "prompt": prompt,
        "size": DEFAULT_SIZE,
        "quality": DEFAULT_QUALITY,
        "n": 1,
    }
    body, content_type = _multipart(fields, "image[]", image)

    headers = {
        "Authorization": "Bearer " + api_key,
        "Content-Type": content_type,
        "User-Agent": "curl/8.0",
    }
    req = urllib.request.Request(EDIT_URL, data=body, headers=headers, method="POST")

    print("Yunwu submitting image edit: model=" + DEFAULT_MODEL + ", size=" + DEFAULT_SIZE)
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        print("Yunwu image edit failed (" + str(exc.code) + "): " + raw[:500])
        return None
    except Exception as exc:  # noqa: BLE001
        print("Yunwu image edit request error: " + str(exc))
        return None

    data = result.get("data") or []
    if not data:
        print("Yunwu returned no image data: " + json.dumps(result)[:500])
        return None

    item = data[0]
    if item.get("url"):
        return item["url"]

    b64 = item.get("b64_json")
    if not b64:
        print("Yunwu response missing b64_json/url: " + json.dumps(item)[:500])
        return None

    out_dir = tempfile.mkdtemp(prefix="clawdess-yunwu-")
    out_path = os.path.join(out_dir, "yunwu-edit.png")
    with open(out_path, "wb") as handle:
        handle.write(base64.b64decode(b64))

    print("Yunwu image ready: " + out_path)
    return "file://" + pathname2url(out_path)

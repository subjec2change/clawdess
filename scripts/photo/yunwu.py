"""Yunwu image edit provider (OpenAI-compatible images edits API)."""

import base64
import json
import os
import tempfile
import urllib.request
import uuid
from urllib.parse import urlparse
from urllib.request import pathname2url


EDIT_URL = "https://yunwu.ai/v1/images/edits"
DEFAULT_MODEL = os.environ.get("CLAWDESS_YUNWU_IMAGE_MODEL", "gpt-image-1")

_CONTENT_TYPES = {
    ".png": "image/png",
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
        parts.append(f'Content-Disposition: form-data; name="{key}"'.encode())
        parts.append(b"")
        parts.append(str(value).encode())

    data, filename, content_type = image
    parts.append(b"--" + boundary.encode())
    parts.append(
        f'Content-Disposition: form-data; name="{image_field}"; filename="{filename}"'.encode()
    )
    parts.append(f"Content-Type: {content_type}".encode())
    parts.append(b"")
    parts.append(data)

    parts.append(b"--" + boundary.encode() + b"--")
    parts.append(b"")
    body = crlf.join(parts)
    return body, f"multipart/form-data; boundary={boundary}"


def generate(api_key, prompt, image_url):
    """Edit *image_url* with *prompt* via Yunwu; return URL or file:// path."""
    try:
        image = _load_image(image_url)
    except Exception as exc:  # noqa: BLE001 - surface any fetch/read failure
        print(f"YUNWU: failed to load reference image: {exc}")
        return None

    fields = {"model": DEFAULT_MODEL, "prompt": prompt, "n": 1}
    body, content_type = _multipart(fields, "image[]", image)

    headers = {
        "Authorization": "Bearer " + api_key,
        "Content-Type": content_type,
        "User-Agent": "curl/8.0",
    }
    req = urllib.request.Request(EDIT_URL, data=body, headers=headers, method="POST")

    print(f"YUNWU submitting image edit: model={DEFAULT_MODEL}")
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        print(f"YUNWU image edit failed ({exc.code}): {raw[:500]}")
        return None
    except Exception as exc:  # noqa: BLE001
        print(f"YUNWU image edit request error: {exc}")
        return None

    data = result.get("data") or []
    if not data:
        print(f"YUNWU returned no image data: {json.dumps(result)[:500]}")
        return None

    item = data[0]
    if item.get("url"):
        return item["url"]

    b64 = item.get("b64_json")
    if not b64:
        print(f"YUNWU response missing b64_json/url: {json.dumps(item)[:500]}")
        return None

    out_dir = tempfile.mkdtemp(prefix="clawdess-yunwu-")
    out_path = os.path.join(out_dir, "yunwu-edit.png")
    with open(out_path, "wb") as handle:
        handle.write(base64.b64decode(b64))

    print(f"YUNWU image ready: {out_path}")
    return "file://" + pathname2url(out_path)

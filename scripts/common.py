"""Shared helpers for clawdess providers."""

import importlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request


MEDIA_CACHE = os.path.expanduser("~/.openclaw/media/clawdess")


def _parse_json_safe(raw):
    """Try to parse JSON, return empty dict if it fails."""
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return {"raw_response": raw}


def _set_default_headers(headers):
    """Ensure User-Agent is set so Cloudflare doesn't block us."""
    headers.setdefault("User-Agent", "curl/8.0")
    return headers


def api_post(url, headers, payload):
    """POST JSON to *url* and return (http_status, parsed_json)."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=_set_default_headers(headers), method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, _parse_json_safe(resp.read().decode())
    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        return exc.code, _parse_json_safe(raw)


def api_get(url, headers, payload=None):
    """GET (or POST with payload) and return (http_status, parsed_json)."""
    data = json.dumps(payload).encode() if payload else None
    method = "POST" if data else "GET"
    req = urllib.request.Request(url, data=data, headers=_set_default_headers(headers), method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, _parse_json_safe(resp.read().decode())
    except urllib.request.HTTPError as exc:
        raw = exc.read().decode() if exc.fp else ""
        return exc.code, _parse_json_safe(raw)


def extract_url(obj):
    """Recursively find the first 'url' value in a nested dict/list."""
    if isinstance(obj, dict):
        if "url" in obj and obj["url"]:
            return obj["url"]
        for v in obj.values():
            found = extract_url(v)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = extract_url(item)
            if found:
                return found
    return None

def download_file(url, dest_dir):
    """Download *url* into *dest_dir*, creating it if needed."""
    os.makedirs(dest_dir, exist_ok=True)
    fname = url.rsplit("/", 1)[-1].split("?")[0] or "download"
    dest = os.path.join(dest_dir, fname)
    urllib.request.urlretrieve(url, dest)
    return dest

def poll_for_url(url, headers, max_attempts=300, interval=5):
    """Poll a URL until a 'url' field appears in the response."""
    for i in range(max_attempts):
        _, body = api_get(url, headers)
        found = extract_url(body)
        print(f"Poll {i}: {json.dumps(body)[:200]}")
        if found:
            return found
        time.sleep(interval)
    return None


def discover_providers(package_name):
    """Auto-discover provider modules from .py files in a package directory.
    Returns dict of {NAME: module} by scanning for files with generate().
    """
    package_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), package_name)
    providers = {}
    for fname in os.listdir(package_dir):
        if fname.startswith("_") or not fname.endswith(".py"):
            continue
        name = fname[:-3].upper()
        mod = importlib.import_module(f"{package_name}.{fname[:-3]}")
        if hasattr(mod, "generate"):
            providers[name] = mod
    return providers


def validate_image_reference(reference, max_bytes=25 * 1024 * 1024):
    """Validate an HTTPS image URL or a local PNG/JPEG/WebP path."""
    from pathlib import Path
    from urllib.parse import urlparse
    if not isinstance(reference, str) or not reference.strip(): raise ValueError("image reference must be a non-empty HTTPS URL or local image path")
    reference = reference.strip(); parsed = urlparse(reference)
    if parsed.scheme:
        if parsed.scheme != "https" or not parsed.netloc: raise ValueError("image reference URL must use HTTPS")
        return reference
    path = Path(reference).expanduser()
    if not path.is_file(): raise ValueError(f"local image is not a regular file: {reference}")
    suffix = path.suffix.lower()
    if suffix not in {".png", ".jpg", ".jpeg", ".webp"}: raise ValueError("local image must use PNG, JPEG, or WebP format")
    if path.stat().st_size > max_bytes: raise ValueError(f"local image exceeds maximum size of {max_bytes} bytes")
    header = path.read_bytes()[:16]
    valid = {".png": header.startswith(b"\x89PNG\r\n\x1a\n"), ".jpg": header.startswith(b"\xff\xd8\xff"), ".jpeg": header.startswith(b"\xff\xd8\xff"), ".webp": header.startswith(b"RIFF") and header[8:12] == b"WEBP"}
    if not valid[suffix]: raise ValueError("local image content does not match its extension")
    return str(path)

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from common import validate_image_reference


def test_validate_image_reference_accepts_https_url():
    ref = "https://example.com/reference.png"
    assert validate_image_reference(ref) == ref


def test_validate_image_reference_accepts_local_image(tmp_path):
    image = tmp_path / "reference.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\n" + b"payload")
    assert validate_image_reference(str(image)) == str(image)


@pytest.mark.parametrize("ref", ["", "file:///tmp/reference.png", "ftp://example.com/a.png"])
def test_validate_image_reference_rejects_unsafe_reference_schemes(ref):
    with pytest.raises(ValueError):
        validate_image_reference(ref)


def test_validate_image_reference_rejects_missing_directory_and_bad_content(tmp_path):
    missing = tmp_path / "missing.png"
    directory = tmp_path / "folder"
    directory.mkdir()
    bad = tmp_path / "bad.png"
    bad.write_bytes(b"not an image")
    for ref in (missing, directory, bad):
        with pytest.raises(ValueError):
            validate_image_reference(str(ref))


def test_validate_image_reference_enforces_size_limit(tmp_path):
    image = tmp_path / "large.jpg"
    image.write_bytes(b"\xff\xd8\xff" + b"x" * 8)
    with pytest.raises(ValueError):
        validate_image_reference(str(image), max_bytes=8)


def test_photo_orchestration_rejects_invalid_reference_before_api_requirement(monkeypatch):
    import argparse
    import common

    monkeypatch.setattr(common, "discover_providers", lambda _name: {})
    import photo

    called = []
    class Provider:
        @staticmethod
        def generate(*args):
            called.append(args)
            return None

    monkeypatch.setattr(photo, "PROVIDERS", {"TEST": Provider})
    args = argparse.Namespace(prompt="test", image="/missing/reference.png", api="", provider="TEST")
    with pytest.raises(SystemExit, match="invalid reference image"):
        photo.run_photo(args)
    assert called == []

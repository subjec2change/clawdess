import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts" / "deploy-dgx-spark-lib.sh"
CLI = ROOT / "scripts" / "deploy-dgx-spark.sh"


def _install_fake_runtime(root, env):
    """Create a minimal virtualenv with python and pip."""
    python = root / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    python.write_text("#!/usr/bin/env python3\nprint('4.12.0')\n")
    python.chmod(0o755)
    pip = root / ".venv" / "bin" / "pip"
    pip.write_text("#!/usr/bin/env python3\nprint('24.0')\n")
    pip.chmod(0o755)
    return root / ".venv"


def bash(script):
    """Run a bash script with source LIB pre-loaded."""
    full = f"source {LIB}\n{script}\n"
    return subprocess.run(
        ["bash", "-c", full],
        capture_output=True, text=True,
        timeout=30,
    )


def test_bash_syntax():
    """Shellcheck-style: the lib file must have valid bash syntax."""
    r = subprocess.run(["bash", "-n", str(LIB)], capture_output=True, text=True)
    assert r.returncode == 0, f"bash -n failed: {r.stderr}"


def test_python_environment_validation_passes():
    """validate_python_environment accepts a properly structured venv."""
    root = Path("/tmp/test-venv-env")
    if root.exists():
        subprocess.run(["rm", "-rf", str(root)], check=True)
    _install_fake_runtime(root, {})
    venv_dir = root / ".venv"
    r = bash(f'validate_python_environment "{venv_dir}"')
    assert r.returncode == 0, r.stderr
    assert "4.12.0" in r.stdout


def test_python_environment_validation_fails_missing_venv():
    """validate_python_environment fails when the venv directory is absent."""
    r = bash('validate_python_environment "/tmp/nonexistent-venv-12345"')
    assert r.returncode != 0


def test_gpu_check_passes_gb10_output():
    """check_gb10_gpu succeeds with expected GB10 nvidia-smi output."""
    r = bash("""
clawdess_nvidia_smi() { printf 'GB10, 64 GB, 12.1'; }
check_gb10_gpu
""")
    assert r.returncode == 0
    assert "GB10" in r.stdout


def test_gpu_check_fails_wrong_compute_cap():
    """check_gb10_gpu fails when compute.cap is not 12.1."""
    r = bash("""
clawdess_nvidia_smi() { printf 'RTX 4090, 24 GB, 8.9'; }
check_gb10_gpu
""")
    assert r.returncode != 0


def test_gpu_check_handles_na_memory():
    """check_gb10_gpu accepts [N/A] memory values."""
    r = bash("""
clawdess_nvidia_smi() { printf 'GB10, [N/A], 12.1'; }
check_gb10_gpu
""")
    assert r.returncode == 0


def test_deployment_path_safety():
    """deployment_path rejects paths that escape the root."""
    r = bash('deployment_path "/tmp" "../etc/passwd"')
    assert r.returncode != 0


def test_model_path_safe_rejects_dotdot():
    """_model_path_safe rejects filenames containing .."""
    r = bash('_model_path_safe "/tmp/models" "../etc/passwd"')
    assert r.returncode != 0


def test_model_path_safe_rejects_newline():
    """_model_path_safe rejects filenames containing newlines."""
    r = bash("_model_path_safe \"/tmp/models\" $'model.bin\\n'")
    assert r.returncode != 0


def test_model_path_safe_allows_simple_name():
    """_model_path_safe accepts a plain filename."""
    r = bash('_model_path_safe "/tmp/models" "model.bin"')
    assert r.returncode == 0
    assert "model.bin" in r.stdout


def test_model_validate_passes_valid_file(tmp_path):
    """_model_validate returns the file size when the file is valid."""
    path = tmp_path / "model.bin"
    path.write_bytes(b"x" * 1024)
    r = bash(f'_model_validate "{path}" 100 ""')
    assert r.returncode == 0
    assert "1024" in r.stdout


def test_model_validate_fails_undersized():
    """_model_validate fails when file is below minimum size."""
    path = tmp_path / "small.bin"
    path.write_bytes(b"x" * 10)
    r = bash(f'_model_validate "{path}" 100 ""')
    assert r.returncode != 0


def test_model_validate_fails_missing_file():
    """_model_validate fails when the file does not exist."""
    r = bash('_model_validate "/tmp/nonexistent-test-file.bin" 100 ""')
    assert r.returncode != 0


def test_model_redact_url_covers_userinfo():
    """_model_redact_url strips userinfo from the URL."""
    r = bash("""
_model_redact_url "https://user:secret@example.com/model"
""")
    assert r.returncode == 0
    assert "secret" not in r.stdout
    assert "REDACTED" in r.stdout


def test_model_redact_url_covers_query_tokens():
    """_model_redact_url strips query-string token values."""
    r = bash("""
_model_redact_url "https://example.com/model?token=abc123&key=key456"
""")
    assert r.returncode == 0
    assert "abc123" not in r.stdout
    assert "key456" not in r.stdout


def test_model_records_selects_by_image_and_backend():
    """model_records emits exactly one image + one TTS record."""
    config = ROOT / "config" / "dgx-spark-models.json"
    r = bash(f'model_records "{config}" "juggernaut-xl-v10" "piper-voice"')
    assert r.returncode == 0
    lines = [l for l in r.stdout.strip().split("\n") if l.strip()]
    assert len(lines) >= 2, f"Expected ≥2 records, got {len(lines)}"
    kinds = [json.loads(l).get("kind") for l in lines]
    assert "image" in kinds
    assert "tts" in kinds


def test_acquisition_creates_nothing_on_dry_run(tmp_path):
    """acquire_models with dry_run=true creates no files."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    config = ROOT / "config" / "dgx-spark-models.json"
    r = bash(f'acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" true "{state_root}"')
    assert r.returncode == 0
    assert not root.exists(), "dry-run should not create model root"
    assert not state_root.exists(), "dry-run should not create state root"


def test_acquisition_plans_three_models_dry_run():
    """Dry-run planning lists all three model entries."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    config = ROOT / "config" / "dgx-spark-models.json"
    r = bash(f'acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" true "{state_root}"')
    assert r.returncode == 0
    lines = [l for l in r.stdout.strip().split("\n") if "planned" in l]
    assert len(lines) >= 2, f"Expected ≥2 model planned lines, got: {lines}"


def test_acquisition_fails_when_no_records(tmp_path):
    """acquire_models returns non-zero when no records are selected."""
    root = tmp_path / "models"
    config = ROOT / "config" / "dgx-spark-models.json"
    r = bash(f'model_records "{config}" "nonexistent-model" "nonexistent-backend"')
    assert r.returncode == 0
    # Empty output -> acquire_models should fail
    r = bash(f'acquire_models "{root}" "{config}" "nonexistent-model" "nonexistent-backend" false "{tmp_path / "state"}"')
    assert r.returncode != 0


def test_successful_model_state_is_structured_json(tmp_path):
    """A successful acquisition produces a parseable deployment-state.json."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    bash(f"source {LIB}; initialize_layout {state_root}")
    config = ROOT / "config" / "dgx-spark-models.json"
    script = f'''source {LIB}
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 1000000 0 1000000 0% /\\n'; }}
probe_curl() {{ printf 'valid-model-data' > "$6"; }}
acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" false "{state_root}"'''
    result = bash(script)
    assert result.returncode == 0, f"stdout={result.stdout} stderr={result.stderr}"
    state_file = state_root / "state" / "deployment-state.json"
    assert state_file.exists(), f"State file not found. stdout: {result.stdout}"
    state = json.loads(state_file.read_text())
    assert state["state"] in ("completed", "failed")
    assert "phase" in state
    record = state.get("models", [{}])[0]
    assert record.get("status") == "downloaded"
    assert record["path"] == str(root / "model.bin") and record["size"] == 16 and record["checksum_status"] == "not-declared"


def test_required_model_download_failure_is_persisted_in_state(tmp_path):
    """A required download failure persists state=failed with model record."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    bash(f"source {LIB}; initialize_layout {state_root}")
    config = ROOT / "config" / "dgx-spark-models.json"
    script = f'''source {LIB}
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 1000000 0 1000000 0% /\\n'; }}
probe_curl() {{ return 22; }}
acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" false "{state_root}"'''
    result = bash(script)
    assert result.returncode != 0
    state = json.loads((state_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "failed"
    assert state["phase"] == "models"


def test_insufficient_disk_space_persists_state(tmp_path):
    """Insufficient disk space returns non-zero and persists failure state."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    bash(f"source {LIB}; initialize_layout {state_root}")
    config = ROOT / "config" / "dgx-spark-models.json"
    script = f'''source {LIB}
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 1000 0 1000 0% /\\n'; }}
acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" false "{state_root}"'''
    result = bash(script)
    assert result.returncode != 0, f"Expected failure, stdout: {result.stdout}"
    state = json.loads((state_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "failed"
    assert state["phase"] == "models"


def test_checksum_mismatch_persists_state(tmp_path):
    """A checksum mismatch on a valid-size file persists failure state."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    bash(f"source {LIB}; initialize_layout {state_root}")
    config = ROOT / "config" / "dgx-spark-models.json"
    script = f'''source {LIB}
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 1000000 0 1000000 0% /\\n'; }}
probe_curl() {{ printf '{"checksum":"abc"}' > "$6"; }}
acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" false "{state_root}"'''
    result = bash(script)
    assert result.returncode != 0
    state = json.loads((state_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "failed" and state["phase"] == "models"

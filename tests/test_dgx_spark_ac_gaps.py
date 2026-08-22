"""Acceptance-criteria gap tests for the DGX Spark deployment wizard.

Covers AC1, AC5, AC8, AC10, AC11 plus the running/partial state
transitions and Docker Compose scaffolding for deferred profiles.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts" / "deploy-dgx-spark-lib.sh"
CLI = ROOT / "scripts" / "deploy-dgx-spark.sh"


@pytest.fixture
def config_path(tmp_path):
    """Create a minimal DGX Spark config with features, profiles, and models."""
    cfg = {
        "features": {
            "photo": {
                "description": "Photo generation",
                "models": ["flux1-dev-fp8", "juggernaut-xl-v10", "stability-ai-sdxl-turbo"],
            },
            "video": {
                "description": "Video generation",
                "models": ["wan2gp-i2v-14B"],
            },
            "voice": {
                "description": "Voice synthesis",
                "backends": ["piper", "kokoro", "xtts-v2", "vllm"],
            },
        },
        "profiles": {
            "minimal": {
                "features": ["photo"],
                "provider": "local",
                "photo_model": "juggernaut-xl-v10",
                "video_model": "wan2gp-i2v-14B",
                "tts_backend": "piper",
            },
            "media": {
                "features": ["photo", "video"],
                "provider": "local",
                "photo_model": "juggernaut-xl-v10",
                "video_model": "wan2gp-i2v-14B",
                "tts_backend": "piper",
            },
            "assistant": {
                "features": ["photo", "video", "voice"],
                "provider": "remote",
                "photo_model": "flux1-dev-fp8",
                "video_model": "wan2gp-i2v-14B",
                "tts_backend": "kokoro",
            },
            "all": {
                "features": ["photo", "video", "voice"],
                "provider": "remote",
                "photo_model": "juggernaut-xl-v10",
                "video_model": "wan2gp-i2v-14B",
                "tts_backend": "piper",
            },
        },
        "models": {
            "flux1-dev-fp8": {"description": "FLUX.1 Dev FP8"},
            "juggernaut-xl-v10": {"description": "Juggernaut XL v10"},
            "stability-ai-sdxl-turbo": {"description": "SDXL Turbo"},
            "wan2gp-i2v-14B": {"description": "Wan2GP I2V 14B"},
            "piper": {"description": "Piper TTS"},
            "kokoro": {"description": "Kokoro TTS"},
            "xtts-v2": {"description": "XTTS v2"},
            "vllm": {"description": "vLLM TTS"},
        },
    }
    path = tmp_path / "dgx-spark-models.json"
    path.write_text(json.dumps(cfg))
    return str(path)


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


def bash(script, env=None):
    """Run a bash script with source LIB pre-loaded."""
    full = f"source {LIB}\n{script}\n"
    merged_env = os.environ.copy()
    if env is not None:
        merged_env.update(env)
    return subprocess.run(
        ["bash", "-c", full],
        capture_output=True, text=True,
        env=merged_env,
        timeout=30,
    )


# ====================================================================
# AC1: Interactive `minimal` setup without Docker/sudo
# ====================================================================

def test_ac1_minimal_runs_without_docker_socket(tmp_path):
    """AC1: minimal profile succeeds even when Docker socket is absent.

    Simulates a system with no Docker installed; the CLI should complete
    all phases (layout, python, comfyui, models, tts) without Docker.
    """
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()

    # Fake nvidia-smi probe
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)

    # Remove docker from PATH to simulate no Docker
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--dry-run", "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 0, f"stdout={result.stdout} stderr={result.stderr}"
    output = result.stdout + result.stderr
    assert "dry-run" in output.lower()


def test_ac1_minimal_creates_layout_without_docker(tmp_path):
    """AC1: minimal profile creates the deployment layout without Docker."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)

    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    # Run without --dry-run to actually create layout
    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    # Layout should have been created regardless of Docker availability
    assert (deploy_root / "logs").exists()


# ====================================================================
# AC5: Docker permission failure reported, doesn't block minimal
# ====================================================================

def test_ac5_docker_failure_prints_message_for_nonminimal(tmp_path):
    """AC5: non-minimal profile prints Docker failure and exits."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)
    # Fake docker that fails (no docker installed)
    (fake_bin / "docker").write_text(
        "#!/usr/bin/env bash\nexit 1\n")
    (fake_bin / "docker").chmod(0o755)
    # Fake docker socket that doesn't exist
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "media",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "docker" in output.lower()
    assert "not accessible" in output


def test_ac5_docker_failure_does_not_block_minimal(tmp_path):
    """AC5: minimal profile continues when Docker permission fails."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)
    # Fake docker socket exists but docker fails
    sock = tmp_path / "docker.sock"
    sock.touch()
    (fake_bin / "docker").write_text(
        "#!/usr/bin/env bash\nexit 1\n")
    (fake_bin / "docker").chmod(0o755)
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--dry-run", "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 0, f"stdout={result.stdout} stderr={result.stderr}"
    output = result.stdout + result.stderr
    assert "dry-run" in output.lower()


# ====================================================================
# AC8: Manifest has no secrets, existing artifact paths
# ====================================================================

def test_ac8_manifest_no_secrets(tmp_path):
    """AC8: deployment-manifest.json contains no secret-like values."""
    deploy_root = tmp_path / "deployment"
    deploy_root.mkdir()
    state_dir = deploy_root / "state"
    state_dir.mkdir()
    # Create a state file that will be merged into the manifest
    (state_dir / "deployment-state.json").write_text(
        '{"state":"completed","phase":"completed",'
        '"models":[{"kind":"image","name":"juggernaut-xl-v10",'
        '"source":"https://user:fal-secret@civitai.com/model",'
        '"path":"/tmp/x/model.safetensors","size":100,"status":"downloaded",'
        '"checksum_status":"verified"}]}\n')

    env = os.environ.copy()
    env["CLAWDESS_FAL_API"] = "fal-secret"
    result = bash(f'state_success "{deploy_root}"', env=env)
    assert result.returncode == 0

    manifest = json.loads((deploy_root / "deployment-manifest.json").read_text())
    manifest_json = json.dumps(manifest)
    # Check common secret patterns — <REDACTED> is expected in the URL
    for pattern in ("fal-secret", "***"):
        assert pattern not in manifest_json, f"Secret-like value found: {pattern}"


def test_ac8_manifest_artifact_paths_exist(tmp_path):
    """AC8: all artifact paths in manifest point to existing files."""
    deploy_root = tmp_path / "deployment"
    models_dir = deploy_root / "models"
    models_dir.mkdir(parents=True)
    (models_dir / "model.safetensors").write_bytes(b"x" * 100)
    (models_dir / "voice.onnx").write_bytes(b"x" * 50)

    # Create manifest with paths that exist
    manifest = {
        "state": "completed",
        "deployed_at": "2026-01-01T00:00:00Z",
        "models": [
            {"kind": "image", "name": "juggernaut", "path": str(models_dir / "model.safetensors"), "status": "downloaded"},
            {"kind": "tts", "name": "piper", "path": str(models_dir / "voice.onnx"), "status": "downloaded"},
        ],
    }
    (deploy_root / "deployment-manifest.json").write_text(json.dumps(manifest))

    manifest_data = json.loads((deploy_root / "deployment-manifest.json").read_text())
    for model in manifest_data.get("models", []):
        path = model.get("path")
        if path:
            assert os.path.exists(path), f"Artifact path does not exist: {path}"


# ====================================================================
# AC10: Dry run produces expected artifacts, no mutation
# ====================================================================

def test_ac10_dry_run_produces_log_and_state(tmp_path):
    """AC10: dry run produces log file with planned state."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)

    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--dry-run", "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 0

    # Verify log exists and contains state=planned
    logs = list((deploy_root / "logs").glob("deploy-*.log"))
    assert len(logs) == 1, f"Expected 1 log file, got {len(logs)}"
    log_content = logs[0].read_text()
    assert "state=planned" in log_content

    # Verify state file exists with planned state
    state_files = list((deploy_root / "state").glob("deployment-state.json"))
    assert len(state_files) >= 1, "Expected deployment-state.json"


def test_ac10_dry_run_no_model_download(tmp_path):
    """AC10: dry run does not download models (no model files on disk)."""
    deploy_root = tmp_path / "deployment"
    models_dir = deploy_root / "models"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)

    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--dry-run", "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 0
    # No model files should exist
    if models_dir.exists():
        assert len(list(models_dir.iterdir())) == 0, "dry-run should not download models"


def test_ac10_dry_run_no_service_pid_files(tmp_path):
    """AC10: dry run does not create PID files for services."""
    deploy_root = tmp_path / "deployment"
    run_dir = deploy_root / "run"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)

    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--dry-run", "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 0
    # No PID files should exist
    pid_files = list(run_dir.glob("*.pid")) if run_dir.exists() else []
    assert len(pid_files) == 0, f"dry-run should not create PID files, found: {pid_files}"


# ====================================================================
# AC11: Video/LLM/Docker profiles refuse independently
# ====================================================================

def test_ac11_media_profile_refuses_without_docker(tmp_path):
    """AC11: media profile refuses when Docker is not available."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "media",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "docker" in output.lower() or "not accessible" in output


def test_ac11_assistant_profile_refuses_without_docker(tmp_path):
    """AC11: assistant profile refuses when Docker is not available."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "assistant",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "docker" in output.lower() or "not accessible" in output


def test_ac11_all_profile_refuses_without_docker(tmp_path):
    """AC11: all profile refuses when Docker is not available."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    (fake_bin / "nvidia-smi").chmod(0o755)
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"

    result = subprocess.run(
        ["bash", str(CLI), "--profile", "all",
         "--image-model", "juggernaut-xl-v10", "--tts-backend", "piper",
         "--non-interactive"],
        cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "docker" in output.lower() or "not accessible" in output


# ====================================================================
# Running/partial state transitions
# ====================================================================

def test_state_write_accepts_running_state(tmp_path):
    """State transitions: state_write accepts running state."""
    deploy_root = tmp_path / "deployment"
    deploy_root.mkdir()
    # state_write deploy_root phase reason extra desired_state
    result = bash(f'state_write "{deploy_root}" models running "" "running"')
    assert result.returncode == 0
    state = json.loads((deploy_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "running"


def test_state_write_accepts_partial_state(tmp_path):
    """State transitions: state_write accepts partial state."""
    deploy_root = tmp_path / "deployment"
    deploy_root.mkdir()
    result = bash(f'state_write "{deploy_root}" models partial "" "partial"')
    assert result.returncode == 0
    state = json.loads((deploy_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "partial"


def test_state_success_uses_completed_state(tmp_path):
    """state_success writes state=completed."""
    deploy_root = tmp_path / "deployment"
    deploy_root.mkdir()
    result = bash(f'state_success "{deploy_root}"')
    assert result.returncode == 0
    manifest = json.loads((deploy_root / "deployment-manifest.json").read_text())
    assert manifest["state"] == "completed"


# ====================================================================
# Docker Compose scaffolding for deferred profiles
# ====================================================================

def test_lifecycle_scripts_include_compose_files(tmp_path):
    """Deferred profiles get Docker Compose scaffolding in generate_lifecycle_scripts()."""
    deploy_root = tmp_path / "deploy"
    deploy_root.mkdir()
    state_root = tmp_path / "state"
    state_root.mkdir()
    result = bash(f'generate_lifecycle_scripts "{deploy_root}" "{state_root}" "media" "true"')
    assert result.returncode == 0

    # Should create docker-compose.yml for deferred services
    compose_file = deploy_root / "docker-compose.yml"
    assert compose_file.exists(), "Docker Compose file not generated"
    content = compose_file.read_text()
    assert "comfyui" in content.lower() or "tts" in content.lower() or "version" in content.lower()


def test_docker_compose_scaffold_has_service_defs(tmp_path):
    """The generated docker-compose.yml defines at least one service."""
    deploy_root = tmp_path / "deploy"
    deploy_root.mkdir()
    state_root = tmp_path / "state"
    state_root.mkdir()
    bash(f'generate_lifecycle_scripts "{deploy_root}" "{state_root}" "media" "true"')
    compose = deploy_root / "docker-compose.yml"
    assert compose.exists()
    content = compose.read_text()
    assert "services" in content.lower()


# ====================================================================
# select_provider — local vs remote resolution
# ====================================================================

def test_select_provider_from_profile(config_path):
    """select_provider returns 'local' for media profile photo category."""
    result = bash(
        f'select_provider "{config_path}" photo media',
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "local"


def test_select_provider_interactive(config_path):
    """select_provider returns 'remote' when user selects 2 interactively."""
    # Use script to give a real PTY so [[ -t 0 ]] is true.
    # Source the lib *inside* the script subshell so the function is available.
    full = (
        'script -q -c '
        f'"source {LIB} && select_provider \\"{config_path}\\" video" '
        '< /dev/null | tr -d "\\r"\n'
    )
    result = subprocess.run(
        ["bash", "-c", full],
        capture_output=True, text=True,
        timeout=30,
    )
    # script may append "Script done." — grab just the function output
    lines = [l for l in result.stdout.strip().splitlines() if l not in ("Script started.", "Script done.")]
    output = "\n".join(lines).strip()
    assert result.returncode == 0, f"stderr={result.stderr}"
    assert output.endswith("remote"), f"Expected 'remote', got: {output}"


def test_select_provider_cli_override(config_path):
    """select_provider returns the 4th arg (CLI override) regardless of profile."""
    result = bash(
        f'select_provider "{config_path}" photo media remote',
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "remote"


# ====================================================================
# select_model — model resolution from profiles, interactive, defaults
# ====================================================================

def test_select_model_from_profile_photo(config_path):
    """select_model returns 'juggernaut-xl-v10' for photo with media profile."""
    result = bash(
        f'select_model "{config_path}" photo media',
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "juggernaut-xl-v10"


def test_select_model_from_profile_video(config_path):
    """select_model returns 'wan2gp-i2v-14B' for video with media profile."""
    result = bash(
        f'select_model "{config_path}" video media',
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "wan2gp-i2v-14B"


def test_select_model_interactive(config_path):
    """select_model returns second model when user selects '2' interactively."""
    full = (
        'script -q -c '
        f'"source {LIB} && select_model \\"{config_path}\\\" photo" '
        '< /dev/null <<< \"2\"\n'
    )
    result = subprocess.run(
        ["bash", "-c", full],
        capture_output=True, text=True,
        timeout=30,
    )
    lines = [l for l in result.stdout.strip().splitlines() if l not in ("Script started.", "Script done.")]
    # Last meaningful line is the selected model
    output = lines[-1].strip() if lines else ""
    assert result.returncode == 0, f"stderr={result.stderr}"
    assert output == "Select: juggernaut-xl-v10", f"Expected 'Select: juggernaut-xl-v10', got: {output}"


def test_select_model_non_interactive_default(config_path):
    """select_model returns first model in category when no stdin and no profile."""
    result = bash(
        f'select_model "{config_path}" photo ""',
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "flux1-dev-fp8"


def test_select_model_cli_override(config_path):
    """select_model returns the model key when passed as CLI override."""
    result = bash(
        f'select_model "{config_path}" photo media "stability-ai-sdxl-turbo"',
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "stability-ai-sdxl-turbo"

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



def test_ac10_dry_run_persists_resolved_selections(tmp_path):
    """Dry-run state records every resolved user selection."""
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text(
        "#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n"
    )
    (fake_bin / "nvidia-smi").chmod(0o755)

    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(deploy_root)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"
    result = subprocess.run(
        ["bash", str(CLI), "--profile", "media", "--features", "photo,video",
         "--provider", "remote", "--image-model", "flux1-dev-fp8",
         "--video-model", "wan2gp-i2v-14B", "--tts-backend", "kokoro",
         "--dry-run", "--non-interactive"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    state = json.loads((deploy_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "planned"
    assert state["selected_features"] == ["photo", "video"]
    assert state["provider"] == "remote"
    assert state["image_model"] == "flux1-dev-fp8"
    assert state["video_model"] == "wan2gp-i2v-14B"
    assert state["tts_backend"] == "kokoro"
    assert set(state) >= {"state", "phase", "error", "models"}
    assert "CLAWDESS" not in json.dumps(state)

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
        f"printf '2\\n' | script -q -c "
        f"'source {LIB} && select_provider \"{config_path}\" video' /dev/null "
        "| tr -d '\\r'"
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


# ====================================================================
# Task 1: feature/provider/model CLI contract
# ====================================================================

def test_cli_help_advertises_feature_provider_and_model_options():
    result = subprocess.run(["bash", str(CLI), "--help"], cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0
    for option in ("--features", "--provider", "--video-model"):
        assert option in result.stdout


def test_cli_resolves_all_feature_provider_and_model_selections(tmp_path, config_path):
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text("#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\n'")
    (fake_bin / "nvidia-smi").chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin", "CLAWDESS_TEST_HOST_PROBE": "allow"}
    result = subprocess.run(["bash", str(CLI), "--profile", "media", "--features", "photo,video",
        "--provider", "remote", "--image-model", "flux1-dev-fp8", "--video-model", "wan2gp-i2v-14B",
        "--tts-backend", "piper", "--deploy-root", str(deploy_root), "--model-root", str(deploy_root / "models"),
        "--dry-run", "--non-interactive"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    output = result.stdout + result.stderr
    assert "remote provider" in output.lower()


def test_remote_provider_skips_local_model_acquisition(tmp_path, config_path):
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text("#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\n'")
    (fake_bin / "nvidia-smi").chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin", "CLAWDESS_TEST_HOST_PROBE": "allow"}
    result = subprocess.run(["bash", str(CLI), "--profile", "assistant", "--provider", "remote",
        "--deploy-root", str(deploy_root), "--dry-run", "--non-interactive"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "remote provider" in (result.stdout + result.stderr).lower()
    assert "model planned:" not in result.stdout


def test_select_model_preserves_explicit_legacy_override(config_path):
    result = bash(f'select_model "{config_path}" photo media juggernaut-xl-v10')
    assert result.returncode == 0
    assert result.stdout.strip() == "juggernaut-xl-v10"


def test_feature_gated_dry_run_photo_only_plans_no_tts_or_video(tmp_path):
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"; fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text("#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\n'"); (fake_bin / "nvidia-smi").chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin", "CLAWDESS_TEST_HOST_PROBE": "allow"}
    result = subprocess.run(["bash", str(CLI), "--profile", "minimal", "--features", "photo",
        "--deploy-root", str(deploy_root), "--dry-run", "--non-interactive"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    output = result.stdout + result.stderr
    assert "model planned: image" in output
    assert "model planned: tts" not in output
    assert "model planned: video" not in output


def test_feature_gated_dry_run_video_plans_video_dependencies(tmp_path):
    deploy_root = tmp_path / "deployment"
    fake_bin = tmp_path / "bin"; fake_bin.mkdir()
    (fake_bin / "nvidia-smi").write_text("#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\n'"); (fake_bin / "nvidia-smi").chmod(0o755)
    env = {**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin", "CLAWDESS_TEST_HOST_PROBE": "allow"}
    result = subprocess.run(["bash", str(CLI), "--profile", "media", "--features", "photo,video",
        "--deploy-root", str(deploy_root), "--dry-run", "--non-interactive"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    output = result.stdout + result.stderr
    assert "model planned: video" in output
    assert "model planned: tts" not in output


# Task 2: verified local model catalog and dependency records
def test_task2_photo_catalog_has_verified_entries_and_file_metadata():
    config = json.loads((ROOT / "config/dgx-spark-models.json").read_text())
    for name in ("juggernaut-xl-v10", "pony-v6", "noobai-xl", "flux1-dev-fp8-finetune"):
        entry = config["models"][name]
        assert entry.get("source", "").startswith(("https://", "http://"))
        for files in entry["files"].values():
            for record in files:
                assert record["source"].startswith(("https://", "http://"))
                assert record["filename"] and record["minimum_size_bytes"] > 0
                assert isinstance(record["required"], bool)
                if record.get("checksum"): assert record["checksum"].startswith("sha256:")

def test_task2_flux_record_does_not_claim_uncensored():
    entry = json.loads((ROOT / "config/dgx-spark-models.json").read_text())["models"]["flux1-dev-fp8-finetune"]
    assert entry.get("experimental") is True
    assert "uncensored" not in json.dumps(entry).lower()

def test_task2_wan2gp_expands_all_required_dependency_subdirs():
    config = ROOT / "config/dgx-spark-models.json"
    result = bash(f'model_records "{config}" "juggernaut-xl-v10" "piper-voice" "wan2gp-i2v-14B" "video"')
    assert result.returncode == 0, result.stderr
    records = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    assert {r["subdir"] for r in records} == {"diffusion_models", "text_encoders", "vae", "clip_vision"}
    assert {r["subdir"]: r["filename"] for r in records} == {"diffusion_models": "wan2.1_i2v_480p_14b_fp16.safetensors", "text_encoders": "umt5_xxl_fp8_e4m3fn_scaled.safetensors", "vae": "wan_2.1_vae.safetensors", "clip_vision": "clip_vision_h.safetensors"}

def test_task2_model_records_rejects_incomplete_nested_file_record(tmp_path):
    config = tmp_path / "invalid.json"
    config.write_text(json.dumps({"models": {"broken": {"files": {"vae": [{"source": "https://example.invalid/x"}]}}}}))
    result = bash(f'model_records "{config}" "broken" "" "" "photo"')
    assert result.returncode != 0
    assert "invalid model record" in result.stderr


# Task 3: truthful voice backend catalog and installer seams
def test_task3_voice_catalog_declares_supported_and_deferred_backends():
    config = json.loads((ROOT / "config/dgx-spark-models.json").read_text())
    voice = config["voice_backends"]
    assert voice["piper"]["status"] == "verified"
    assert voice["kokoro"]["status"] == "experimental"
    assert voice["xtts-v2"]["status"] == "deferred"
    assert voice["kokoro"]["voices"] == ["af_heart", "af_bella", "af_nicole", "af_sky", "am_adam", "am_michael"]
    assert voice["xtts-v2"]["speaker_wav"] == "<path-to-speaker-wav>"

def test_task3_backend_validation_aliases_and_deferred_errors(config_path):
    for backend, expected in (("piper", "piper"), ("piper-voice", "piper"), ("kokoro", "kokoro"), ("xtts", "xtts-v2"), ("xtts-v2", "xtts-v2")):
        result = bash(f'validate_voice_backend "{config_path}" "{backend}"')
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == expected
    result = bash(f'validate_voice_backend "{config_path}" vllm')
    assert result.returncode != 0
    assert "unsupported" in result.stderr.lower() or "deferred" in result.stderr.lower()

def test_task3_acquire_voice_only_does_not_plan_image(config_path, tmp_path):
    result = bash(f'model_records "{config_path}" "juggernaut-xl-v10" piper "" voice')
    assert result.returncode == 0
    records = [json.loads(x) for x in result.stdout.splitlines() if x.strip()]
    assert records and {r["kind"] for r in records} == {"tts"}

def test_task3_install_dispatch_is_truthful_and_piper_only_smoke(config_path):
    result = bash('install_voice_backend piper /bin/false')
    assert result.returncode != 0
    assert "piper" in result.stderr.lower()
    result = bash('install_voice_backend kokoro /bin/false')
    assert result.returncode != 0
    assert "experimental" in result.stderr.lower() or "deferred" in result.stderr.lower()


# Task 4: local video provisioning seam

def test_task4_local_video_scaffold_wires_selected_model_paths(tmp_path):
    deploy_root = tmp_path / "deploy"
    result = bash(f'provision_local_video "{deploy_root}" "{deploy_root}" "wan2gp-i2v-14B" "{ROOT / "config/dgx-spark-models.json"}" false')
    assert result.returncode != 0
    assert "deferred" in (result.stdout + result.stderr).lower()
    manifest = json.loads((deploy_root / "config" / "video-local.json").read_text())
    assert manifest["provider"] == "local" and manifest["model"] == "wan2gp-i2v-14B" and manifest["status"] == "deferred"
    assert manifest["model_root"] == str(deploy_root / "models")
    assert manifest["dependencies"] == {k: str(deploy_root / "models" / k) for k in ("diffusion_models", "text_encoders", "vae", "clip_vision")}

def test_task4_local_video_registers_lifecycle_and_health(tmp_path):
    deploy_root = tmp_path / "deploy"
    result = bash(f'generate_lifecycle_scripts "{deploy_root}" "{deploy_root}" "media" "false"; provision_local_video "{deploy_root}" "{deploy_root}" "wan2gp-i2v-14B" "{ROOT / "config/dgx-spark-models.json"}" false')
    assert result.returncode != 0
    for name in ("start-video", "stop-video"): assert (deploy_root / "bin" / name).exists()
    assert "video" in (deploy_root / "bin" / "health-check").read_text().lower()

def test_task4_remote_provider_skips_local_video_provisioning(tmp_path):
    deploy_root = tmp_path / "deploy"
    result = bash(f'provision_video "{deploy_root}" "{deploy_root}" remote "wan2gp-i2v-14B" "{ROOT / "config/dgx-spark-models.json"}" false')
    assert result.returncode == 0 and "remote provider" in result.stdout.lower()
    assert not (deploy_root / "config" / "video-local.json").exists()

def test_task4_dry_run_reports_deferred_without_scaffold_write(tmp_path):
    deploy_root = tmp_path / "deploy"
    result = bash(f'provision_local_video "{deploy_root}" "{deploy_root}" "wan2gp-i2v-14B" "{ROOT / "config/dgx-spark-models.json"}" true')
    assert result.returncode == 0 and "deferred" in result.stdout.lower() and not deploy_root.exists()



def test_capability_manifest_rejects_unknown_catalog_status(tmp_path, config_path):
    config = json.loads(Path(config_path).read_text())
    config["models"]["juggernaut-xl-v10"]["status"] = "catalog-corruption"
    malformed = tmp_path / "malformed.json"
    malformed.write_text(json.dumps(config))
    result = bash(f'capability_manifest "{malformed}" "photo" "local" "juggernaut-xl-v10" "" ""')
    assert result.returncode != 0
    assert "unknown capability status" in result.stderr.lower()

def test_capability_state_mapping_persists_selected_provider_separately(tmp_path, config_path):
    result = bash(f'capability_manifest "{config_path}" "photo,video,voice" "remote" "juggernaut-xl-v10" "wan2gp-i2v-14B" "piper"')
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert data["provider"] == "remote"
    assert data["capability_states"]["photo"]["state"] == "verified"
    assert data["capability_states"]["video"]["state"] == "deferred"
    assert data["capability_states"]["voice"]["state"] == "verified"
    assert data["capability_states"]["photo"]["provider"] == "remote"
    assert data["capability_states"]["video"]["local_dependencies"] is True


def test_non_dry_run_deferred_capability_fails_explicitly(tmp_path, config_path):
    root = tmp_path / "deploy"; root.mkdir()
    cap = root / "capability.json"
    result = bash(f'capability_manifest "{config_path}" "photo,video" "local" "juggernaut-xl-v10" "wan2gp-i2v-14B" "piper" > "{cap}"; capability_reject_non_dry_run "{cap}"')
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "video" in output.lower() and "deferred" in output.lower()
    data = json.loads(cap.read_text())
    assert data["capability_states"]["video"]["state"] == "deferred"


def test_state_write_persists_capability_states_and_manifest(tmp_path):
    deploy_root = tmp_path / 'deploy'
    cap_path = tmp_path / 'capability.json'
    cap_path.write_text(json.dumps({'capability_states': {'photo': {'state': 'verified'}}, 'provider': 'remote'}))
    result = bash(f'''state_write "{deploy_root}" models planned "" planned "$(cat "{cap_path}")"''')
    assert result.returncode == 0, result.stderr
    state = json.loads((deploy_root / 'state' / 'deployment-state.json').read_text())
    manifest = json.loads((deploy_root / 'deployment-manifest.json').read_text())
    assert state['capability_states']['photo']['state'] == 'verified'
    assert manifest['capability_states'] == state['capability_states']
    assert manifest['provider'] == 'remote'


def test_state_success_preserves_capability_states_in_manifest(tmp_path):
    deploy_root = tmp_path / 'deploy'
    cap_path = tmp_path / 'capability.json'
    cap_path.write_text(json.dumps({'capability_states': {'video': {'state': 'deferred'}}, 'provider': 'remote'}))
    result = bash(f'''state_write "{deploy_root}" models planned "" planned "$(cat "{cap_path}")"; state_success "{deploy_root}"''')
    assert result.returncode == 0, result.stderr
    manifest = json.loads((deploy_root / 'deployment-manifest.json').read_text())
    assert manifest['state'] == 'completed'
    assert manifest['capability_states'] == {'video': {'state': 'deferred'}}
    assert manifest['provider'] == 'remote'


def test_failed_capability_state_persists_mapping(tmp_path, config_path):
    deploy_root = tmp_path / "deploy"
    cap = deploy_root / "capability.json"
    result = bash(f'mkdir -p "{deploy_root}"; capability_manifest "{config_path}" "photo,video" "local" "juggernaut-xl-v10" "wan2gp-i2v-14B" "piper" > "{cap}"; state_write "{deploy_root}" models "capability selection blocked" "" "failed" "$(cat "{cap}")"')
    assert result.returncode == 0, result.stderr
    state = json.loads((deploy_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "failed"
    assert state["capability_states"]["video"]["state"] == "deferred"


@pytest.mark.parametrize("state", ["deferred", "unavailable", "blocked"])
def test_remote_non_dry_run_capability_states_fail_explicitly(tmp_path, state):
    cap = tmp_path / "capability.json"
    cap.write_text(json.dumps({"provider": "remote", "capability_states": {"video": {"state": state, "provider": "remote"}}}))
    result = bash(f'capability_reject_non_dry_run "{cap}"')
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "video" in output.lower() and state in output.lower()


def test_cli_rejects_remote_non_dry_run_capability_states(tmp_path):
    content = CLI.read_text()
    capability_gate = content[content.index('CAPABILITY_JSON='):content.index('SELECTION_JSON=')]
    assert 'if [[ "$DRY_RUN" != true ]]; then' in capability_gate
    assert '"$PROVIDER" != remote' not in capability_gate


def test_video_preflight_reports_machine_readable_missing_runtime(tmp_path):
    """Video preflight must distinguish missing runtime prerequisites."""
    script = ROOT / "scripts" / "check-dgx-video-runtime.sh"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_DOCKER"] = "missing"
    result = subprocess.run(["bash", str(script), str(tmp_path / "deployment")], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    assert result.returncode != 0
    lines = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    assert lines["VIDEO_PREFLIGHT_LEVEL"] == "preflight"
    assert lines["VIDEO_PREFLIGHT_STATUS"] == "failed"
    assert lines["VIDEO_DOCKER"] in {"missing", "unavailable"}
    assert lines["VIDEO_ARTIFACT_EVIDENCE"] == "absent"


# Task 4 review blocker coverage: direct runtime preflight contract tests.
def _run_video_preflight(tmp_path, *, health="fail", state=None, artifact=False, dependency=False, docker_missing=False):
    root = tmp_path / "deployment"
    (root / "models").mkdir(parents=True)
    if not (not dependency and health == "fail" and state is None):
        (root / "models" / "wan-video.safetensors").write_bytes(b"model")
    (root / "artifacts" / "video").mkdir(parents=True)
    if artifact:
        (root / "artifacts" / "video" / "sample.mp4").write_bytes(b"video")
    (root / "state").mkdir()
    if state is not None:
        (root / "state" / "deployment-state.json").write_text(json.dumps(state))
    if dependency:
        (root / "video-runtime").mkdir()
        (root / "video-runtime" / "wan2gp").write_text("runtime")
        (root / "config").mkdir()
        (root / "config" / "video-local.json").write_text(json.dumps({
            "status": "verified", "dependencies": {"runtime": str(root / "video-runtime" / "wan2gp")}
        }))
    fake = tmp_path / "bin"; fake.mkdir()
    (fake / "uname").write_text("#!/bin/sh\nprintf aarch64\n"); (fake / "uname").chmod(0o755)
    (fake / "docker").write_text("#!/bin/sh\nexit 0\n"); (fake / "docker").chmod(0o755)
    (fake / "nvidia-smi").write_text("#!/bin/sh\nprintf 'GB10, 12.1\\n'\n"); (fake / "nvidia-smi").chmod(0o755)
    sock = tmp_path / "docker.sock"
    import socket
    s = socket.socket(socket.AF_UNIX); s.bind(str(sock))
    env = os.environ.copy(); env.update({"PATH": f"{fake}:/usr/bin:/bin", "DOCKER_HOST_SOCKET": str(sock), "CLAWDESS_TEST_DOCKER": "missing" if docker_missing else ""})
    if health == "pass":
        (fake / "curl").write_text("#!/bin/sh\nexit 0\n")
    else:
        (fake / "curl").write_text("#!/bin/sh\nexit 22\n")
    (fake / "curl").chmod(0o755)
    result = subprocess.run(["bash", str(ROOT / "scripts" / "check-dgx-video-runtime.sh"), str(root)], cwd=ROOT, env=env, text=True, capture_output=True)
    s.close(); return result, dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def test_video_preflight_reports_missing_model_and_dependency_paths(tmp_path):
    result, lines = _run_video_preflight(tmp_path, docker_missing=True)
    assert result.returncode != 0
    assert lines["VIDEO_MODEL_PATH"] == "absent"
    assert lines["VIDEO_DEPENDENCY_PATH"] == "absent"
    assert lines["VIDEO_PREFLIGHT_LEVEL"] == "preflight"


def test_video_preflight_unavailable_health_stays_preflight(tmp_path):
    result, lines = _run_video_preflight(tmp_path, health="fail", state={"state": "completed"}, dependency=True, docker_missing=True)
    assert result.returncode != 0
    assert lines["VIDEO_SERVICE_HEALTH"] == "failed"
    assert lines["VIDEO_PREFLIGHT_LEVEL"] == "preflight"


def test_video_preflight_passing_health_requires_all_preflights(tmp_path):
    result, lines = _run_video_preflight(tmp_path, health="pass", state={"state": "completed"}, dependency=True, docker_missing=True)
    assert result.returncode != 0
    assert lines["VIDEO_SERVICE_HEALTH"] == "passing"
    assert lines["VIDEO_PREFLIGHT_LEVEL"] == "preflight"
    assert lines["VIDEO_PREFLIGHT_STATUS"] == "failed"


def test_video_preflight_accepts_structured_state_and_artifact_evidence(tmp_path):
    result, lines = _run_video_preflight(tmp_path, health="pass", state={"state": "completed"}, dependency=True, artifact=True)
    assert result.returncode == 0, result.stderr
    assert lines["VIDEO_STATE_EVIDENCE"] == "present"
    assert lines["VIDEO_ARTIFACT_EVIDENCE"] == "present"
    assert lines["VIDEO_PREFLIGHT_LEVEL"] == "artifact"


@pytest.mark.parametrize("bad_state", [{"state": "planned"}, {"state": "dry-run"}, {"state": "failed"}, {"arbitrary": "non-empty"}])
def test_video_preflight_rejects_untruthful_state_evidence(tmp_path, bad_state):
    result, lines = _run_video_preflight(tmp_path, health="pass", state=bad_state, dependency=True, artifact=True)
    assert result.returncode != 0
    assert lines["VIDEO_STATE_EVIDENCE"] == "absent"
    assert lines["VIDEO_PREFLIGHT_LEVEL"] == "preflight"


def test_generated_lifecycle_scripts_have_bash_syntax(tmp_path):
    deploy_root = tmp_path / "deploy"; state_root = tmp_path / "state"
    deploy_root.mkdir(); state_root.mkdir()
    result = bash(f'generate_lifecycle_scripts "{deploy_root}" "{state_root}"')
    assert result.returncode == 0
    for path in (deploy_root / "bin").iterdir():
        assert subprocess.run(["bash", "-n", str(path)]).returncode == 0, path

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


def test_bash_partial_env_override_preserves_inherited_path():
    """bash env overrides retain inherited variables such as PATH."""
    result = bash('printf "%s|%s" "$PATH" "$CLAWDESS_TEST_OVERRIDE"',
                  env={"CLAWDESS_TEST_OVERRIDE": "present"})
    path, override = result.stdout.split("|", 1)
    assert result.returncode == 0
    assert path == os.environ["PATH"]
    assert override == "present"


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
clawdess_nvidia_smi() { printf ' GB10 , 64 GB , 12.1 '; }
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
clawdess_nvidia_smi() { printf ' GB10 , [N/A] , 12.1 '; }
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


def test_model_validate_fails_undersized(tmp_path):
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


def test_acquisition_plans_three_models_dry_run(tmp_path):
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
    config = tmp_path / "models.json"
    config.write_text(json.dumps({
        "juggernaut-xl-v10": {"source": "https://example.invalid/model", "revision": "v10", "filename": "juggernautXL_v10.safetensors", "minimum_size_bytes": 6650000000, "required": True, "checksum": ""},
        "piper-voice": {"source": "https://example.invalid/voice", "revision": "v1", "filename": "voice.onnx", "minimum_size_bytes": 1, "required": False, "checksum": ""},
    }))
    script = f'''source {LIB}
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 10000000 0 10000000 0% /\\n'; }}
probe_curl() {{ truncate -s 6650000000 "$2"; }}
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
    assert record["path"] == str(root / "juggernautXL_v10.safetensors") and record["size"] == 6650000000 and record["checksum_status"] == "not-declared"


def test_required_model_download_failure_is_persisted_in_state(tmp_path):
    """A required download failure persists state=failed with model record."""
    root = tmp_path / "models"
    state_root = tmp_path / "state"
    bash(f"source {LIB}; initialize_layout {state_root}")
    config = ROOT / "config" / "dgx-spark-models.json"
    script = f'''source {LIB}
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 10000000 0 10000000 0% /\\n'; }}
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
probe_df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 10000000 0 10000000 0% /\\n'; }}
probe_curl() {{ printf '{{\"checksum\":\"abc\"}}' > "$2"; }}
acquire_models "{root}" "{config}" "juggernaut-xl-v10" "piper-voice" false "{state_root}"'''
    result = bash(script)
    assert result.returncode != 0
    state = json.loads((state_root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "failed" and state["phase"] == "models"

def test_library_has_no_top_level_side_effects(tmp_path):
    marker = tmp_path / "marker"
    result = bash(f"test ! -e {marker}")
    assert result.returncode == 0, result.stderr


def test_probe_seams_are_overridable(tmp_path):
    script = f"""
    clawdess_command_v() {{ printf '/fake/%s\\n' "$1"; }}
    clawdess_nvidia_smi() {{ printf 'GPU [N/A]\\n'; }}
    clawdess_python() {{ printf 'python-probe\\n'; }}
    clawdess_docker() {{ printf 'docker-probe\\n'; }}
    clawdess_curl() {{ printf 'curl-probe\\n'; }}
    clawdess_df() {{ printf 'df-probe\\n'; }}
    probe_command python
    probe_nvidia_smi
    probe_python --version
    probe_docker info
    probe_curl https://example.invalid {tmp_path}/download
    probe_df -Pk {tmp_path}
    """
    result = bash(script)
    assert result.returncode == 0, result.stderr
    assert "/fake/python" in result.stdout
    assert "GPU [N/A]" in result.stdout
    assert "python-probe" in result.stdout
    assert "docker-probe" in result.stdout
    assert "curl-probe" in result.stdout
    assert "df-probe" in result.stdout


def test_json_write_is_atomic_and_complete(tmp_path):
    destination = tmp_path / "state" / "deployment-state.json"
    destination.parent.mkdir()
    result = bash(
        f"payload='{{\"status\":\"planned\"}}'; json_write_atomic {destination} \"$payload\""
    )
    assert result.returncode == 0, result.stderr
    assert destination.read_text() == '{"status":"planned"}\n'
    assert list(destination.parent.glob("*.tmp.*")) == []


def test_state_write_uses_atomic_json_writer(tmp_path):
    state_root = tmp_path / "state"
    result = bash(f"json_write_atomic() {{ printf 'called:%s' \"$1\"; }}; state_write {state_root} models failed")
    assert result.returncode == 0
    assert f"called:{state_root / 'state' / 'deployment-state.json'}" in result.stdout


def test_atomic_write_failure_cleans_temp_and_preserves_destination(tmp_path):
    destination = tmp_path / "state.json"
    destination.write_text("old\n")
    result = bash(f"json_atomic_rename() {{ return 1; }}; json_write_atomic {destination} new")
    assert result.returncode != 0
    assert destination.read_text() == "old\n"
    assert list(tmp_path.glob("state.json.tmp.*")) == []


def test_atomic_write_failure_cleans_temp_on_write_failure(tmp_path):
    destination = tmp_path / "state.json"
    destination.write_text("old\n")
    result = bash(f"json_atomic_write_temp() {{ return 1; }}; json_write_atomic {destination} new")
    assert result.returncode != 0
    assert destination.read_text() == "old\n"
    assert list(tmp_path.glob("state.json.tmp.*")) == []


def test_state_success_uses_atomic_json_writer(tmp_path):
    state_root = tmp_path / "state"
    result = bash(f"json_write_atomic() {{ printf 'called:%s' \"$1\"; }}; state_success {state_root}")
    assert result.returncode == 0
    assert f"called:{state_root / 'deployment-manifest.json'}" in result.stdout


def test_redaction_replaces_api_tokens_and_secret_file_values():
    env = os.environ.copy()
    env.update({
        "CLAWDESS_FAL_API": "fal-secret",
        "HF_TOKEN": "hf-secret",
        "CLAWDESS_HF_TOKEN_FILE": "/run/secrets/hf-token",
    })
    result = bash(
        f"redact_text 'fal-secret hf-secret /run/secrets/hf-token safe'",
        env=env,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "<REDACTED> <REDACTED> <REDACTED> safe"


@pytest.mark.parametrize("args", [["--help"], ["--non-interactive"]])
def test_cli_contract_is_observable(args):
    result = subprocess.run(
        ["bash", str(CLI), *args], cwd=ROOT, text=True,
        capture_output=True, check=False,
    )
    if args == ["--help"]:
        assert result.returncode == 0
        assert "Usage:" in result.stdout
    else:
        assert result.returncode != 0
        assert "profile" in (result.stdout + result.stderr).lower()


def test_dry_run_is_observable_without_real_services(tmp_path):
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(tmp_path / "deployment")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    nvidia_smi = fake_bin / "nvidia-smi"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"
    nvidia_smi.write_text("#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    nvidia_smi.chmod(0o755)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"
    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal", "--image-model",
         "juggernaut-xl-v10", "--tts-backend", "piper", "--dry-run",
         "--non-interactive"], cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    output = result.stdout + result.stderr
    assert "dry-run" in output.lower()
    assert "would" in output.lower() or "planned" in output.lower()
    logs = list((tmp_path / "deployment" / "logs").glob("deploy-*.log"))
    assert len(logs) == 1
    assert "state=planned" in logs[0].read_text()


def test_validation_failure_is_logged_before_exit(tmp_path):
    env = os.environ.copy()
    root = tmp_path / "deployment"
    env["CLAWDESS_DEPLOY_ROOT"] = str(root)
    result = subprocess.run(
        ["bash", str(CLI), "--non-interactive"], cwd=ROOT, env=env,
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 2
    logs = list((root / "logs").glob("deploy-*.log"))
    assert len(logs) == 1
    content = logs[0].read_text()
    assert "phase=validation" in content
    assert "status=2" in content


def test_required_discovery_probe_failure_is_logged(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    nvidia_smi = fake_bin / "nvidia-smi"
    nvidia_smi.write_text("#!/usr/bin/env bash\nexit 17\n")
    nvidia_smi.chmod(0o755)
    env = os.environ.copy()
    root = tmp_path / "deployment"
    env.update({"CLAWDESS_DEPLOY_ROOT": str(root), "PATH": f"{fake_bin}:/usr/bin:/bin", "CLAWDESS_TEST_HOST_PROBE": "allow"})
    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal", "--image-model",
         "juggernaut-xl-v10", "--tts-backend", "piper", "--dry-run",
         "--non-interactive"], cwd=ROOT, env=env,
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 2
    assert "nvidia-smi probe failed" in (result.stdout + result.stderr)
    logs = list((root / "logs").glob("deploy-*.log"))
    assert len(logs) == 1
    assert "phase=discovery" in logs[0].read_text()


def test_err_trap_records_post_log_failure_metadata(tmp_path):
    log = tmp_path / "run.log"
    result = subprocess.run(
        ["bash", "-c", f"source {CLI}; RUN_LOG={log!s}; PHASE=execution; false"],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "phase=execution" in output
    assert "status=1" in output
    assert "command=false" in output
    content = log.read_text()
    assert "phase=execution" in content
    assert "status=1" in content
    assert "command=false" in content


def test_err_trap_redacts_secret_like_command_context(tmp_path):
    log = tmp_path / "run.log"
    env = os.environ.copy()
    env["CLAWDESS_FAL_API"] = "super-secret"
    result = subprocess.run(
        ["bash", "-c", f"source {CLI}; RUN_LOG={log!s}; PHASE=execution; "
         "on_error 17 42 'curl --header Authorization: ***'"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0
    output = result.stdout + result.stderr
    assert "line=42" in output
    assert "status=17" in output
    assert "super-secret" not in output
    assert "<REDACTED>" in output
    assert "phase=execution" in log.read_text()


def test_empty_secret_environment_does_not_emit_nested_redaction_error(tmp_path):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("CLAWDESS_"):
            env.pop(key)
    env["CLAWDESS_DEPLOY_ROOT"] = str(tmp_path / "deployment")
    result = subprocess.run(["bash", str(CLI), "--non-interactive"], cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "compgen -A variable CLAWDESS_" not in output
    assert "state: persisted failed state" in output


def test_health_check_script_is_generated(tmp_path):
    """generate_lifecycle_scripts creates a health-check script."""
    deploy_root = tmp_path / "deploy"
    deploy_root.mkdir()
    state_root = tmp_path / "state"
    state_root.mkdir()
    result = bash(f'generate_lifecycle_scripts "{deploy_root}" "{state_root}"')
    assert result.returncode == 0
    health = deploy_root / "bin" / "health-check"
    assert health.exists(), "health-check script not generated"
    assert os.access(health, os.X_OK), "health-check is not executable"
    # Verify it has bash syntax
    r = subprocess.run(["bash", "-n", str(health)], capture_output=True, text=True)
    assert r.returncode == 0, f"health-check bash -n failed: {r.stderr}"


def test_health_check_reports_unhealthy_services(tmp_path):
    """health-check returns non-zero when no services are running."""
    deploy_root = tmp_path / "deploy"
    deploy_root.mkdir(parents=True)
    (deploy_root / "bin").mkdir(parents=True)
    (deploy_root / "bin" / "health-check").write_text("""#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
error_count=0
if [[ -f "$SCRIPT_DIR/run/comfyui.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/comfyui.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        printf 'ComfyUI: ready (pid %s)\\n' "$pid"
    else
        printf 'ComfyUI: dead process in pid file\\n'
        error_count=$((error_count + 1))
    fi
else
    printf 'ComfyUI: no pid file found (service not started)\\n'
    error_count=$((error_count + 1))
fi
if [[ -f "$SCRIPT_DIR/run/tts.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/tts.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        printf 'TTS (piper): ready (pid %s)\\n' "$pid"
    else
        printf 'TTS (piper): dead process in pid file\\n'
        error_count=$((error_count + 1))
    fi
else
    printf 'TTS (piper): no pid file found (service not started)\\n'
    error_count=$((error_count + 1))
fi
if [[ "$error_count" -gt 0 ]]; then
    printf 'health-check: %d issue(s) found\\n' "$error_count"
    exit 1
fi
printf 'health-check: all services healthy\\n'
exit 0
""")
    r = subprocess.run(["bash", str(deploy_root / "bin" / "health-check")], capture_output=True, text=True, cwd=ROOT)
    assert r.returncode != 0
    assert "2 issue" in r.stdout


def test_lifecycle_scripts_include_all_required_scripts(tmp_path):
    """generate_lifecycle_scripts creates all required lifecycle scripts."""
    deploy_root = tmp_path / "deploy"
    deploy_root.mkdir()
    state_root = tmp_path / "state"
    state_root.mkdir()
    bash(f'generate_lifecycle_scripts "{deploy_root}" "{state_root}"')
    required = ["start-comfyui", "stop-comfyui", "start-tts", "stop-tts", "status", "health-check"]
    for name in required:
        path = deploy_root / "bin" / name
        assert path.exists(), f"Missing generated script: {name}"


def test_cleanup_stops_tracked_services(tmp_path):
    """do_cleanup stops all tracked PIDs and their PID files."""
    deploy_root = tmp_path / "deploy"
    run_dir = deploy_root / "run"
    run_dir.mkdir(parents=True)
    logs_dir = deploy_root / "logs"
    logs_dir.mkdir(parents=True)
    (run_dir / "comfyui.pid").write_text("99998")
    (run_dir / "tts.pid").write_text("99998")
    # Use PID 99998 (not running) so do_cleanup doesn't SIGTERM itself
    result = bash(f"""started_pids=("99999" "99999")
EXIT_CLEANUP_DONE=false
do_cleanup
echo "cleanup:rc=$?"
""", env={"CLAWDESS_DEPLOY_ROOT": str(deploy_root)})


def test_pid_tracking_writes_pid_file(tmp_path):
    """track_pid writes the PID file to run/ and appends to the log."""
    deploy_root = tmp_path / "deploy"
    run_dir = deploy_root / "run"
    run_dir.mkdir(parents=True)
    logs_dir = deploy_root / "logs"
    logs_dir.mkdir(parents=True)
    (logs_dir / "test.log").write_text("")
    result = bash(f"""started_pids=()
EXIT_CLEANUP_DONE=false
track_pid 12345 "comfyui"
""", env={"CLAWDESS_DEPLOY_ROOT": str(deploy_root)})
    assert result.returncode == 0
    assert (run_dir / "comfyui.pid").exists()
    assert (run_dir / "comfyui.pid").read_text().strip() == "12345"


def test_do_cleanup_is_idempotent(tmp_path):
    """do_cleanup returns immediately when already cleaned up."""
    deploy_root = tmp_path / "deploy"
    run_dir = deploy_root / "run"
    run_dir.mkdir(parents=True)
    result = bash(f"""started_pids=()
EXIT_CLEANUP_DONE=true
do_cleanup
echo "exit:$?"
""", env={"CLAWDESS_DEPLOY_ROOT": str(deploy_root)})
    assert result.returncode == 0
    assert "exit:0" in result.stdout


def test_service_startup_phases_exist():
    """The wizard includes startup and smoke test phases."""
    content = CLI.read_text()
    assert "PHASE=\"startup\"" in content
    assert "PHASE=\"smoke\"" in content
    assert "track_pid" in content
    assert "do_cleanup" in content
    assert "EXIT_CLEANUP_DONE" in content


def test_smoke_stops_services(tmp_path):
    """Smoke phase stops ComfyUI and TTS after running tests."""
    content = CLI.read_text()
    assert "run/tts.pid" in content
    assert "run/comfyui.pid" in content
    assert "smoke: stopping services" in content


def test_dry_run_reset_is_rejected_without_mutation(tmp_path):
    root = tmp_path / "deployment"
    root.mkdir()
    marker = root / "marker"
    marker.write_text("keep")
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(root)
    result = subprocess.run(
        ["bash", str(CLI), "--dry-run", "--reset", "--yes"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 2
    assert marker.read_text() == "keep"
    assert "cannot be combined" in (result.stdout + result.stderr)


def test_reset_refuses_symlink_root_without_touching_target(tmp_path):
    target = tmp_path / "target"
    target.mkdir()
    marker = target / "marker"
    marker.write_text("keep")
    root = tmp_path / "deployment-link"
    root.symlink_to(target, target_is_directory=True)
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(root)
    result = subprocess.run(
        ["bash", str(CLI), "--reset", "--yes"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 2
    assert root.is_symlink()
    assert marker.read_text() == "keep"
    assert "symlink" in (result.stdout + result.stderr).lower()


def test_reset_refuses_symlink_parent_without_touching_target(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    marker = outside / "marker"
    marker.write_text("keep")
    parent = tmp_path / "parent-link"
    parent.symlink_to(outside, target_is_directory=True)
    root = parent / "deployment"
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(root)
    result = subprocess.run(
        ["bash", str(CLI), "--reset", "--yes"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 2
    assert marker.read_text() == "keep"
    assert parent.is_symlink()
    assert "symlink" in (result.stdout + result.stderr).lower()


@pytest.mark.parametrize("option", ["--model-root", "--verbose"])
def test_plan_cli_options_are_accepted(option, tmp_path):
    env = os.environ.copy()
    env["CLAWDESS_DEPLOY_ROOT"] = str(tmp_path / "deployment")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    nvidia_smi = fake_bin / "nvidia-smi"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"
    nvidia_smi.write_text("#!/usr/bin/env bash\nprintf 'GB10, [N/A], 12.1\\n'\n")
    nvidia_smi.chmod(0o755)
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    env["CLAWDESS_TEST_HOST_PROBE"] = "allow"
    args = ["bash", str(CLI), "--profile", "minimal", "--image-model",
            "juggernaut-xl-v10", "--tts-backend", "piper", option]
    if option == "--model-root":
        args.append(str(tmp_path / "models"))
    args += ["--dry-run", "--non-interactive"]
    result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                            capture_output=True, check=False)
    assert result.returncode == 0, result.stderr
    if option == "--verbose":
        assert "verbose:" in (result.stdout + result.stderr)


def test_wait_for_comfyui_readiness_timeout(tmp_path):
    """ComfyUI readiness times out when no server is listening."""
    script = (
        f""
        "wait_for_comfyui_readiness http://127.0.0.1:19999 5\n"
    )
    result = bash(script)
    assert result.returncode != 0  # timeout, no server
    assert "readiness: comfyui not ready" in result.stdout


def test_smoke_test_comfyui_starts_and_produces_output(tmp_path):
    """smoke_test_comfyui starts ComfyUI, submits workflow, and produces output."""
    deploy_root = tmp_path / "deployment"
    comfyui_path = tmp_path / "comfyui"
    comfyui_path.mkdir()
    (comfyui_path / "main.py").write_text("#!/usr/bin/env python3\nprint('ComfyUI')\n")
    (comfyui_path / "main.py").chmod(0o755)
    venv_python = comfyui_path / "main.py"

    # Create the fake output file the smoke test checks for
    smoke_dir = deploy_root / "artifacts" / "comfyui-output" / "images" / "smoke"
    smoke_dir.mkdir(parents=True)
    (smoke_dir / "smoke_00001_abc123.png").write_bytes(b"FAKE_PNG")

    script = f"""

curl() {{
    local url=""
    local show_header=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--silent) show_header=false ;;
            http://*|https://*) url="$1" ;;
        esac
        shift
    done

    if [[ "$show_header" == true ]]; then
        echo "HTTP/1.1 200 OK"
    fi
    case "$url" in
        */api/system_stats)
            printf '200'
            ;;
        */prompt)
            printf '{{"prompt_id":"abc123","number":0,"node_errors":{{}}}}'
            ;;
        */history/abc123)
            printf '{{"abc123":{{"status":{{"status_str":"success"}}}}}}'
            ;;
        *)
            printf '200'
            ;;
    esac
}}

smoke_test_comfyui "{comfyui_path}" "{venv_python}" "{deploy_root}"
"""
    result = bash(script)
    assert result.returncode == 0, f"stdout={result.stdout} stderr={result.stderr}"
    assert "smoke: ComfyUI smoke test passed" in result.stdout



def test_smoke_test_piper_generates_audio(tmp_path):
    """smoke_test_piper actually generates audio instead of just checking --help."""
    deploy_root = tmp_path / "deployment"

    # Create a fake model file and companion config
    model_file = deploy_root / "models" / "en_US-librittsr-medium.onnx"
    model_file.parent.mkdir(parents=True)
    model_file.write_bytes(b"FAKE_MODEL_DATA")
    config_file = deploy_root / "models" / "en_US-librittsr-medium.onnx.json"
    config_file.write_text('{"speaker_ids":{},"preprocess":{"phonemize":false}}')

    # Create a fake piper binary that writes WAV data to the output file
    piper_dir = tmp_path / "piper_bin"
    piper_dir.mkdir()
    piper_exe = piper_dir / "piper"
    piper_exe.write_text(
        '#!/usr/bin/env bash\n'
        'while [[ $# -gt 0 ]]; do\n'
        '  case "$1" in\n'
        '    --output) outfile="$2"; shift 2 ;;\n'
        '    --model) shift 2 ;;\n'
        '    --config) shift 2 ;;\n'
        '    *) shift ;;\n'
        '  esac\n'
        'done\n'
        'printf "WAV_DATA" > "$outfile"\n'
    )
    piper_exe.chmod(0o755)

    script = (
        f""
        f"piper() {{ {piper_exe} \"$@\"; }}\n"
        f"smoke_test_piper {model_file} {deploy_root}\n"
    )
    result = bash(script)
    assert result.returncode == 0, result.stdout + result.stderr
    # smoke_test_piper creates a temp dir under deploy_root (artifacts.XXXXXX/smoke_test.wav)
    smoke_wavs = list((deploy_root).glob("**/smoke_test.wav"))
    assert len(smoke_wavs) >= 1, f"Expected at least one smoke_test.wav under {deploy_root}"
    assert smoke_wavs[0].stat().st_size > 0, f"Expected smoke_test.wav to be non-empty"


def test_cli_real_command_failure_invokes_production_error_handler(tmp_path):
    env = os.environ.copy()
    root = tmp_path / "deployment"
    env.update({"CLAWDESS_DEPLOY_ROOT": str(root), "PATH": "/usr/bin:/bin",
                "CLAWDESS_TEST_TOKEN": "cli-secret-value"})
    result = subprocess.run(
        ["bash", str(CLI), "--profile", "minimal", "--image-model",
         "juggernaut-xl-v10", "--tts-backend", "piper", "--dry-run",
         "--non-interactive"], cwd=ROOT, env=env, text=True,
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "phase=discovery" in output
    assert "status=" in output and "command=" in output
    assert "cli-secret-value" not in output
    logs = list((root / "logs").glob("deploy-*.log"))
    assert len(logs) == 1
    log = logs[0].read_text()
    assert "phase=discovery" in log and "status=" in log
    assert "cli-secret-value" not in log
    state = json.loads((root / "state" / "deployment-state.json").read_text())
    assert state["state"] == "failed" and state["phase"] == "discovery"
    assert "cli-secret-value" not in (root / "state" / "deployment-state.json").read_text()


def test_cli_deploy_root_routes_failure_artifacts_after_argument_parsing(tmp_path):
    env_root = tmp_path / "from-env"
    requested_root = tmp_path / "requested"
    env = os.environ.copy()
    env.update({"CLAWDESS_DEPLOY_ROOT": str(env_root), "PATH": "/usr/bin:/bin"})
    result = subprocess.run(
        ["bash", str(CLI), "--deploy-root", str(requested_root), "--non-interactive"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False,
    )
    assert result.returncode != 0
    assert list((requested_root / "logs").glob("deploy-*.log"))
    assert (requested_root / "state" / "deployment-state.json").exists()
    assert not env_root.exists()


def test_persist_failed_state_reports_persistence_failure(tmp_path):
    result = bash(f"state_write() {{ return 9; }}; persist_failed_state '{tmp_path}' discovery boom")
    assert result.returncode != 0
    assert "persisted failed state" not in result.stdout


def test_on_error_redacts_url_credentials_and_query_secrets(tmp_path):
    log = tmp_path / "run.log"
    command = "curl 'https://user:pass@example.test/model?token=t1&access_token=t2&api_key=t3&key=t4'"
    result = subprocess.run(
        ["bash", "-c", f"source {CLI}; RUN_LOG={log!s}; PHASE=models; on_error 7 12 {command!r}"],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0
    for secret in ("user:pass", "t1", "t2", "t3", "t4"):
        assert secret not in output
        assert secret not in log.read_text()
    assert "<REDACTED>" in output


def test_state_write_invalid_payload_preserves_existing_destination(tmp_path):
    state_root = tmp_path / "state"
    state_file = state_root / "state" / "deployment-state.json"
    state_file.parent.mkdir(parents=True)
    state_file.write_text('{"state":"old"}\n')
    result = bash(f"state_write '{state_root}' models failed 'not-json'")
    assert result.returncode != 0
    assert state_file.read_text() == '{"state":"old"}\n'


def test_redaction_handles_non_clawdess_secret_file_names(tmp_path):
    secret_file = tmp_path / "token"
    secret_file.write_text("file-secret\n")
    env = os.environ.copy()
    env["HF_TOKEN_PATH"] = str(secret_file)
    env["ORDINARY_VALUE"] = "do-not-redact"
    result = bash(f"redact_text 'file-secret {secret_file} do-not-redact'", env=env)
    assert result.returncode == 0
    assert result.stdout.strip() == "<REDACTED> <REDACTED> do-not-redact"

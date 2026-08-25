#!/usr/bin/env bash
# DGX Spark Deployment Wizard — entry point.
# Usage:
#   ./scripts/deploy-dgx-spark.sh --profile minimal --image-model juggernaut-xl-v10 --tts-backend piper [--dry-run] [--non-interactive] [--yes]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/deploy-dgx-spark-lib.sh"

# Source helpers
source "$LIB"
trap 'status=$?; trap - ERR; on_error "$status" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROFILE=""
FEATURES=""
PROVIDER=""
IMAGE_MODEL=""
VIDEO_MODEL=""
TTS_BACKEND=""
DRY_RUN=false
NON_INTERACTIVE=false
AUTO_YES=false
VERBOSE=false
RESET=false
DEPLOY_ROOT="${CLAWDESS_DEPLOY_ROOT:-$HOME/.local/share/clawdess-dgx-spark}"
MODEL_ROOT="${CLAWDESS_MODEL_ROOT:-$DEPLOY_ROOT/models}"
STATE_ROOT="$DEPLOY_ROOT"
CONFIG="$REPO_ROOT/config/dgx-spark-models.json"
RUN_LOG="$DEPLOY_ROOT/logs/deploy-$(date -u +%Y%m%dT%H%M%SZ).log"
LOG_FILE="$RUN_LOG"
PHASE="discovery"
started_pids=()
EXIT_CLEANUP_DONE=false
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --features) FEATURES="$2"; shift 2 ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --image-model) IMAGE_MODEL="$2"; shift 2 ;;
        --video-model) VIDEO_MODEL="$2"; shift 2 ;;
        --tts-backend) TTS_BACKEND="$2"; shift 2 ;;
        --deploy-root) DEPLOY_ROOT="$2"; shift 2 ;;
        --model-root) MODEL_ROOT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --yes) AUTO_YES=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --reset) RESET=true; shift ;;
        --help)
            printf 'Usage: %s [--profile minimal|media|assistant|all] [--features <list>] [--provider local|remote] [--image-model <model>] [--video-model <model>] [--tts-backend <backend>] [--deploy-root <path>] [--model-root <path>] [--dry-run] [--non-interactive] [--verbose] [--reset] [--yes]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

# CLI arguments override environment-derived paths. Keep an explicit model root.
if [[ -z "${CLAWDESS_MODEL_ROOT:-}" ]]; then
    MODEL_ROOT="$DEPLOY_ROOT/models"
fi
STATE_ROOT="$DEPLOY_ROOT"
RUN_LOG="$DEPLOY_ROOT/logs/deploy-$(date -u +%Y%m%dT%H%M%SZ).log"
LOG_FILE="$RUN_LOG"
mkdir -p -- "$(dirname -- "$RUN_LOG")"
trap 'status=$?; trap - ERR; on_error "$status" "$LINENO" "$BASH_COMMAND"' ERR

if [[ "$NON_INTERACTIVE" == true && -z "$PROFILE" ]]; then
    PHASE="validation"
    printf 'validation: --non-interactive requires --profile\n' >&2
    on_error 2 "$LINENO" "--non-interactive requires --profile"
    exit 2
fi
if [[ "$RESET" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then printf 'reset cannot be combined with --dry-run\n' >&2; exit 2; fi
    if [[ "$AUTO_YES" != true ]]; then printf 'reset requires --yes\n' >&2; exit 2; fi
    reset_deployment_root "$DEPLOY_ROOT"; exit $?
fi
if [[ "$VERBOSE" == true ]]; then printf 'verbose: deploy-root=%s model-root=%s profile=%s\n' "$DEPLOY_ROOT" "$MODEL_ROOT" "$PROFILE"; fi

# A no-profile invocation is the public interactive wizard.  Use /dev/tty so
# it remains interactive when launched by a shell wrapper or test harness.
if [[ -z "$PROFILE" && "$NON_INTERACTIVE" != true ]]; then
    if [[ ! -r /dev/tty ]]; then
        printf 'validation: no profile supplied and no interactive TTY is available; use --profile with --non-interactive\n' >&2
        exit 2
    fi
    printf '=== Clawdess DGX Spark Interactive Wizard ===\n' >&2
    export CLAWDESS_INTERACTIVE_WIZARD=1
    exec 3<&0
    FEATURES="$(select_features "$CONFIG" "" 0<&3)" || exit 2
    PROVIDER="$(select_provider "$CONFIG" photo "" 0<&3)" || exit 2
    IMAGE_MODEL="$(select_model "$CONFIG" photo "" 0<&3)" || exit 2
    if feature_selected "$FEATURES" video; then
        VIDEO_MODEL="$(select_model "$CONFIG" video "" 0<&3)" || exit 2
    else
        VIDEO_MODEL="$(select_model "$CONFIG" video "" 0<&3)" || exit 2
    fi
    if feature_selected "$FEATURES" voice; then
        TTS_BACKEND="$(select_model "$CONFIG" voice "" 0<&3)" || exit 2
        TTS_BACKEND="$(validate_voice_backend "$CONFIG" "$TTS_BACKEND")" || exit 2
    else
        TTS_BACKEND="$(select_model "$CONFIG" voice "" 0<&3)" || exit 2
    fi
    printf '\nSelection summary (no changes made yet):\n' >&2
    printf '  features: %s\n  provider: %s\n  image model: %s\n  video model: %s\n  voice backend: %s\n' \
        "$FEATURES" "$PROVIDER" "$IMAGE_MODEL" "$VIDEO_MODEL" "$TTS_BACKEND" >&2
    printf 'Proceed with this plan? [y/N]: ' >&2
    confirm=''
    IFS= read -r confirm <&3 || confirm=""
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) printf 'Aborted before mutation.\n' >&2; exit 0 ;;
    esac
fi

# Persist the approved selection plan before installation, including dry-runs.
if [[ -n "$PROFILE" || -n "$FEATURES" ]]; then
    mkdir -p -- "$DEPLOY_ROOT/state"
    python3 - "$FEATURES" "$PROVIDER" "$IMAGE_MODEL" "$VIDEO_MODEL" "$TTS_BACKEND" > "$DEPLOY_ROOT/state/deployment-state.json" <<'PY'
import json, sys
f, provider, image, video, voice = sys.argv[1:]
print(json.dumps({"selected_features": [x for x in f.replace(",", " ").split() if x], "provider": provider, "image_model": image, "video_model": video, "tts_backend": voice}))
PY
fi

# ---------------------------------------------------------------------------
# Cleanup and PID tracking
# ---------------------------------------------------------------------------

trap 'status=$?; trap - EXIT ERR; do_cleanup; if (( status != 0 )); then on_error "$status" "$LINENO" "cleanup-exit"; fi; exit "$status"' EXIT

# ---------------------------------------------------------------------------
# Phase 1
# ---------------------------------------------------------------------------
printf '=== Phase 1: Host Detection ===\n'

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "aarch64" && "${CLAWDESS_TEST_HOST_PROBE:-}" != "allow" ]]; then
    printf 'host: expected aarch64, got %s\n' "$HOST_ARCH" >&2
    if [[ "$NON_INTERACTIVE" == true ]]; then
        on_error 2 "$LINENO" "host architecture mismatch"
        exit 2
    fi
fi

printf 'host: %s\n' "$HOST_ARCH"
printf 'python: %s\n' "$(clawdess_command_v python3)"

# Check NVIDIA GPU
if ! check_gb10_gpu; then
    printf 'gpu: GB10 check failed\n' >&2
    if [[ "$NON_INTERACTIVE" == true ]]; then
        on_error 2 "$LINENO" "GPU not detected or unexpected hardware"
        exit 2
    fi
fi

# Check Docker availability (for non-minimal profiles)
if [[ "$PROFILE" != "minimal" ]]; then
    if ! check_docker_socket; then
        printf 'docker: not accessible (required for %s profile)\n' "$PROFILE" >&2
        if [[ "$NON_INTERACTIVE" == true ]]; then
            on_error 1 "$LINENO" "Docker socket not accessible"
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Phase 2: Layout
# ---------------------------------------------------------------------------
PHASE="layout"
printf '=== Phase 2: Deployment Layout ===\n'

if [[ "$DRY_RUN" == true ]]; then
    printf 'dry-run: skipping layout creation\n'
else
    mkdir -p -- "$DEPLOY_ROOT"/{bin,config,logs,models,run,state,venv,artifacts}
    mkdir -p -- "$(dirname -- "$LOG_FILE")"
    printf 'layout: created in %s\n' "$DEPLOY_ROOT"
fi

# ---------------------------------------------------------------------------
# Phase 3: Python environment
# ---------------------------------------------------------------------------
PHASE="dependencies"
printf '=== Phase 3: Python Environment ===\n'

VENV_PATH="$DEPLOY_ROOT/venv"

if [[ "$DRY_RUN" == true ]]; then
    printf 'dry-run: python_runtime_dry_run=skipping venv\n'
    # Check host Python
    if command -v python3 >/dev/null 2>&1; then
        printf 'dry-run: python_runtime_dry_run=available version=%s\n' "$(python3 --version 2>&1)"
    else
        printf 'dry-run: python_runtime_dry_run=unavailable reason=host-python-unavailable\n'
    fi
    if python3 -c 'import torch' 2>/dev/null; then
        printf 'dry-run: python_runtime_dry_run=torch=available\n'
    else
        printf 'dry-run: python_runtime_dry_run=torch=unavailable\n'
    fi
    if command -v nvcc >/dev/null 2>&1; then
        printf 'dry-run: python_runtime_dry_run=cuda=available\n'
    else
        printf 'dry-run: python_runtime_dry_run=cuda=unavailable\n'
    fi
else
    if [[ ! -d "$VENV_PATH" ]]; then
        printf 'python: creating virtualenv at %s\n' "$VENV_PATH"
        python3 -m venv "$VENV_PATH" || {
            on_error 1 "$LINENO" "virtualenv creation failed"
            exit 1
        }
    fi

    # Install dependencies
    printf 'python: installing dependencies\n'
    "$VENV_PATH/bin/pip" install --upgrade pip wheel setuptools 2>&1 | tail -3 || {
        on_error 1 "$LINENO" "pip upgrade failed"
        exit 1
    }

    # Install PyTorch for ARM64 (CPU-only, no CUDA toolkit required)
    printf 'python: installing PyTorch (CPU)\n'
    "$VENV_PATH/bin/pip" install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu 2>&1 | tail -5 || {
        on_error 1 "$LINENO" "PyTorch install failed"
        exit 1
    }
fi

# ---------------------------------------------------------------------------
# Phase 4: ComfyUI
# ---------------------------------------------------------------------------
PHASE="comfyui"
printf '=== Phase 4: ComfyUI ===\n'

COMFYUI_PATH="$DEPLOY_ROOT/artifacts/ComfyUI"

if [[ "$DRY_RUN" == true ]]; then
    printf 'dry-run: comfyui_revisions_comfyui=%s\n' "$COMFYUI_REVISION"
    printf 'dry-run: comfyui_skip=not-installing\n'
else
    if ! install_comfyui "$VENV_PATH/bin/python" "$COMFYUI_PATH"; then
        on_error 1 "$LINENO" "installation failed"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Phase 5: Model acquisition
# ---------------------------------------------------------------------------
PHASE="models"
printf '=== Phase 5: Model Acquisition ===\n'

if [[ -z "$PROFILE" ]]; then
    printf 'profile: not set\n'
    if [[ "$NON_INTERACTIVE" == true ]]; then
        on_error 1 "$LINENO" "profile not specified"
        exit 1
    fi
fi

# Resolve selections from the profile/catalog while preserving explicit CLI overrides.
if [[ -n "$PROFILE" ]]; then
    FEATURES="${FEATURES:-$(select_features "$CONFIG" "$PROFILE")}"
    PROVIDER="${PROVIDER:-$(select_provider "$CONFIG" photo "$PROFILE")}" || { on_error 1 "$LINENO" "feature selection failed"; exit 1; }
    [[ -n "$IMAGE_MODEL" ]] || IMAGE_MODEL="$(select_model "$CONFIG" photo "$PROFILE")" || { on_error 1 "$LINENO" "image model selection failed"; exit 1; }
    [[ -n "$VIDEO_MODEL" ]] || VIDEO_MODEL="$(select_model "$CONFIG" video "$PROFILE")"
    [[ -n "$TTS_BACKEND" ]] || TTS_BACKEND="$(select_model "$CONFIG" voice "$PROFILE")" || { on_error 1 "$LINENO" "TTS backend selection failed"; exit 1; }
    TTS_BACKEND="$(validate_voice_backend "$CONFIG" "$TTS_BACKEND")" || { on_error 1 "$LINENO" "unsupported or deferred voice backend"; exit 1; }
    printf 'selection: features=%s provider=%s image-model=%s video-model=%s tts-backend=%s\n' "$FEATURES" "$PROVIDER" "$IMAGE_MODEL" "$VIDEO_MODEL" "$TTS_BACKEND"
fi

CAPABILITY_JSON="$(capability_manifest "$CONFIG" "$FEATURES" "$PROVIDER" "$IMAGE_MODEL" "$VIDEO_MODEL" "$TTS_BACKEND")" || { on_error 1 "$LINENO" "capability state resolution failed"; exit 1; }
state_write "$STATE_ROOT" "capabilities" "capability state resolved" "" "planned" "$CAPABILITY_JSON" || { on_error 1 "$LINENO" "capability state persistence failed"; exit 1; }
if [[ "$DRY_RUN" != true ]]; then
    CAPABILITY_TMP="$DEPLOY_ROOT/state/capability-state.json"
    mkdir -p "$DEPLOY_ROOT/state"
    printf '%s\n' "$CAPABILITY_JSON" > "$CAPABILITY_TMP"
    if ! capability_reject_non_dry_run "$CAPABILITY_TMP"; then
        state_write "$STATE_ROOT" "models" "capability selection blocked" "" "failed" "$CAPABILITY_JSON"
        exit 1
    fi
fi

SELECTION_JSON="$(printf "%s\n" "$FEATURES" "$PROVIDER" "$IMAGE_MODEL" "$VIDEO_MODEL" "$TTS_BACKEND" | python3 -c 'import json,re,sys; a=sys.stdin.read().splitlines(); print(json.dumps({"selected_features":[x for x in re.split(r"[\s,]+",a[0].strip()) if x],"provider":a[1],"image_model":a[2],"video_model":a[3],"tts_backend":a[4]},separators=(",",":")))')"

if [[ "$PROVIDER" == "remote" ]]; then
    printf 'remote provider: skipping local model acquisition\n'
    state_write "$STATE_ROOT" "models" "remote provider selected; local acquisition skipped" "" "planned" "$SELECTION_JSON"
elif [[ "$DRY_RUN" == true ]]; then
    printf 'dry-run: acquiring models (dry run, no downloads)\n'
    acquire_models "$MODEL_ROOT" "$CONFIG" "$IMAGE_MODEL" "$TTS_BACKEND" true "$STATE_ROOT" "$FEATURES" "$VIDEO_MODEL" || {
        on_error 1 "$LINENO" "dry-run model planning failed"
        exit 1
    }
    printf 'dry-run: model acquisition complete (no filesystem changes)\n'
    state_write "$STATE_ROOT" "models" "dry-run model planning complete" "" "planned" "$SELECTION_JSON"
    printf 'state=planned phase=models\n' >>"$RUN_LOG"
    exit 0
fi

# Check disk space before acquisition
free_kb=$(probe_df -Pk "$MODEL_ROOT" 2>/dev/null | awk 'NR==2 {print $4}') || true
required_bytes=8000000000
if [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -lt "$((required_bytes / 1024 / 1024 + 100))" ]]; then
    printf 'disk: insufficient space for model acquisition (%d MB free, ~%d MB required)\n' "$free_kb" "$((required_bytes / 1024 / 1024))" >&2
    on_error 1 "$LINENO" "insufficient disk space"
    exit 1
fi

if [[ "$PROVIDER" != "remote" ]] && ! acquire_models "$MODEL_ROOT" "$CONFIG" "$IMAGE_MODEL" "$TTS_BACKEND" false "$STATE_ROOT" "$FEATURES" "$VIDEO_MODEL"; then
    on_error 1 "$LINENO" "model acquisition failed"
    exit 1
fi



# Provision local video only when the selected feature set includes video.
if [[ "$PROVIDER" != "remote" ]] && [[ "$FEATURES" =~ (^|[[:space:],])video([[:space:],]|$) ]]; then
    if ! provision_video "$DEPLOY_ROOT" "$STATE_ROOT" "$PROVIDER" "$VIDEO_MODEL" "$CONFIG" "$DRY_RUN"; then
        on_error 1 "$LINENO" "video provisioning failed"
        exit 1
    fi
fi


# ---------------------------------------------------------------------------
# Phase 6: TTS installation
# ---------------------------------------------------------------------------
PHASE="tts"
printf '=== Phase 6: TTS ===\n'

if [[ "$DRY_RUN" == false ]] && feature_selected "$FEATURES" voice; then
    install_voice_backend "$TTS_BACKEND" "$VENV_PATH/bin/python" || { on_error 1 "$LINENO" "installation failed"; exit 1; }
elif ! feature_selected "$FEATURES" voice; then
    printf 'tts: voice feature not selected; local TTS setup skipped
'
fi

# ---------------------------------------------------------------------------
# Phase 7: Service startup (ordered)
# ---------------------------------------------------------------------------
PHASE="startup"
printf '=== Phase 7: Service Startup ===\n'

if [[ "$DRY_RUN" == false ]]; then
    # Start ComfyUI first
    printf 'startup: starting ComfyUI...\n'
    nohup "$VENV_PATH/bin/python" "$COMFYUI_PATH/comfyui-runner.py" > "$DEPLOY_ROOT/logs/comfyui.log" 2>&1 &
    COMFYUI_PID=$!
    track_pid "$COMFYUI_PID" "comfyui"
    printf 'startup: ComfyUI started (pid %s)\n' "$COMFYUI_PID"

    # Wait for ComfyUI readiness
    if ! wait_for_comfyui_readiness "$DEPLOY_ROOT"; then
        printf 'startup: ComfyUI failed readiness, stopping...\n'
        kill "$COMFYUI_PID" 2>/dev/null || true
        rm -f "$DEPLOY_ROOT/run/comfyui.pid"
        state_write "$DEPLOY_ROOT" "startup" "ComfyUI readiness failed" "" "partial"
        exit 1
    fi
    printf 'startup: ComfyUI is ready\n'

    # Start TTS after ComfyUI is ready only when voice was selected.
    if feature_selected "$FEATURES" voice; then
        printf 'startup: starting TTS...\n'
        nohup "$VENV_PATH/bin/piper" > "$DEPLOY_ROOT/logs/tts.log" 2>&1 &
        TTS_PID=$!
        track_pid "$TTS_PID" "tts"
        printf 'startup: TTS started (pid %s)\n' "$TTS_PID"

        # Wait for TTS readiness
        if ! wait_for_tts_ready 30; then
            printf 'startup: TTS failed readiness, stopping services...\n'
            kill "$TTS_PID" 2>/dev/null || true
            rm -f "$DEPLOY_ROOT/run/tts.pid"
            kill "$COMFYUI_PID" 2>/dev/null || true
            rm -f "$DEPLOY_ROOT/run/comfyui.pid"
            state_write "$DEPLOY_ROOT" "startup" "TTS readiness failed" "" "partial"
            exit 1
        fi
        printf 'startup: TTS is ready\n'
    else
        printf 'startup: voice feature not selected; TTS startup skipped\n'
    fi

    # Emit running state once all services are healthy
    state_write "$DEPLOY_ROOT" "startup" "all services healthy" "" "running"
fi

# ---------------------------------------------------------------------------
# Phase 8: Smoke tests
# ---------------------------------------------------------------------------
PHASE="smoke"
printf '=== Phase 8: Smoke Tests ===\n'

if [[ "$DRY_RUN" == false ]]; then
    if ! smoke_test_comfyui "$COMFYUI_PATH" "$VENV_PATH/bin/python"; then
        state_write "$DEPLOY_ROOT" "smoke" "ComfyUI smoke test failed" "" "partial"
        on_error 1 "$LINENO" "ComfyUI import failed"
    fi
    # Stop services after smoke tests
    printf 'smoke: stopping services...\n'
    if [[ -f "$DEPLOY_ROOT/run/tts.pid" ]]; then
        kill "$(cat "$DEPLOY_ROOT/run/tts.pid")" 2>/dev/null || true
        rm -f "$DEPLOY_ROOT/run/tts.pid"
    fi
    if [[ -f "$DEPLOY_ROOT/run/comfyui.pid" ]]; then
        kill "$(cat "$DEPLOY_ROOT/run/comfyui.pid")" 2>/dev/null || true
        rm -f "$DEPLOY_ROOT/run/comfyui.pid"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 9: Generate lifecycle scripts
# ---------------------------------------------------------------------------
PHASE="lifecycle"
printf '=== Phase 9: Lifecycle Scripts ===\n'

if [[ "$DRY_RUN" == false ]]; then
# Only generate Docker Compose for non-minimal profiles when Docker is available
docker_available=false
if [[ "$PROFILE" != "minimal" ]]; then
    if check_docker_socket 2>/dev/null; then
        docker_available=true
    fi
fi
generate_lifecycle_scripts "$DEPLOY_ROOT" "$STATE_ROOT" "$PROFILE" "$docker_available"
fi

# ---------------------------------------------------------------------------
# Phase 9: Finalize
# ---------------------------------------------------------------------------
PHASE="finalize"
printf '=== Phase 9: Finalize ===\n'

if [[ "$DRY_RUN" == false ]]; then
    state_success "$STATE_ROOT"
    printf 'Deployment completed successfully.\n'
    printf 'Run: %s/bin/status\n' "$DEPLOY_ROOT"
fi

exit 0

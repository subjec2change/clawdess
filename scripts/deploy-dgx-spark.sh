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
IMAGE_MODEL=""
TTS_BACKEND=""
DRY_RUN=false
NON_INTERACTIVE=false
AUTO_YES=false
DEPLOY_ROOT="${CLAWDESS_DEPLOY_ROOT:-$HOME/.local/share/clawdess-dgx-spark}"
MODEL_ROOT="${CLAWDESS_MODEL_ROOT:-$DEPLOY_ROOT/models}"
STATE_ROOT="$DEPLOY_ROOT/state"
CONFIG="$REPO_ROOT/config/dgx-spark-models.json"
RUN_LOG="$DEPLOY_ROOT/logs/deploy-$(date -u +%Y%m%dT%H%M%SZ).log"
LOG_FILE="$RUN_LOG"
PHASE="discovery"
mkdir -p -- "$(dirname -- "$RUN_LOG")"
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --image-model) IMAGE_MODEL="$2"; shift 2 ;;
        --tts-backend) TTS_BACKEND="$2"; shift 2 ;;
        --deploy-root) DEPLOY_ROOT="$2"; shift 2 ;;
        --model-root) MODEL_ROOT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --yes) AUTO_YES=true; shift ;;
        --help)
            printf 'Usage: %s [--profile minimal|media|assistant|all] [--image-model <model>] [--tts-backend <backend>] [--dry-run] [--non-interactive] [--yes]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Phase 1: Detect host
# ---------------------------------------------------------------------------
printf '=== Phase 1: Host Detection ===\n'

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "aarch64" ]]; then
    printf 'host: expected aarch64, got %s\n' "$HOST_ARCH" >&2
    if [[ "$NON_INTERACTIVE" == true ]]; then
        on_error 1 "$LINENO" "host architecture mismatch"
        exit 1
    fi
fi

printf 'host: %s\n' "$HOST_ARCH"
printf 'python: %s\n' "$(clawdess_command_v python3)"

# Check NVIDIA GPU
if ! check_gb10_gpu; then
    printf 'gpu: GB10 check failed\n' >&2
    if [[ "$NON_INTERACTIVE" == true ]]; then
        on_error 1 "$LINENO" "GPU not detected or unexpected hardware"
        exit 1
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

if [[ "$DRY_RUN" == true ]]; then
    printf 'dry-run: acquiring models (dry run, no downloads)\n'
    acquire_models "$MODEL_ROOT" "$CONFIG" "$IMAGE_MODEL" "$TTS_BACKEND" true "$STATE_ROOT" || {
        on_error 1 "$LINENO" "dry-run model planning failed"
        exit 1
    }
    printf 'dry-run: model acquisition complete (no filesystem changes)\n'
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

if ! acquire_models "$MODEL_ROOT" "$CONFIG" "$IMAGE_MODEL" "$TTS_BACKEND" false "$STATE_ROOT"; then
    on_error 1 "$LINENO" "model acquisition failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 6: TTS installation
# ---------------------------------------------------------------------------
PHASE="tts"
printf '=== Phase 6: TTS ===\n'

if [[ "$DRY_RUN" == false ]]; then
    install_piper_tts "$VENV_PATH/bin/python" || {
        on_error 1 "$LINENO" "installation failed"
        exit 1
    }
fi

# ---------------------------------------------------------------------------
# Phase 7: Smoke tests
# ---------------------------------------------------------------------------
PHASE="smoke"
printf '=== Phase 7: Smoke Tests ===\n'

if [[ "$DRY_RUN" == false ]]; then
    if ! smoke_test_comfyui "$COMFYUI_PATH" "$VENV_PATH/bin/python"; then
        on_error 1 "$LINENO" "ComfyUI import failed"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Phase 8: Generate lifecycle scripts
# ---------------------------------------------------------------------------
PHASE="lifecycle"
printf '=== Phase 8: Lifecycle Scripts ===\n'

if [[ "$DRY_RUN" == false ]]; then
    generate_lifecycle_scripts "$DEPLOY_ROOT" "$STATE_ROOT"
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

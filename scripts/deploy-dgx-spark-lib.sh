#!/usr/bin/env bash
# Shared, side-effect-free helpers for the DGX Spark deployment wizard.
# Source this file; the executable wizard owns shell options and lifecycle.
set -o nounset

# Command probes are functions rather than aliases so tests can override them.
clawdess_command_v() { command -v "$1"; }
clawdess_nvidia_smi() { nvidia-smi "$@"; }
clawdess_python() { python3 "$@"; }
clawdess_curl() { command curl --fail --location --silent "$@"; }
clawdess_df() { command df -h "$@"; }
clawdess_docker() { command docker "$@"; }
clawdess_json() { python3 -m json.tool "$@"; }

probe_command() { clawdess_command_v "$@"; }
probe_nvidia_smi() { clawdess_nvidia_smi "$@"; }
probe_python() { clawdess_python "$@"; }
probe_docker() { clawdess_docker "$@"; }

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

# deployment_path ROOT NAME - resolve a path within ROOT with safety checks.
# Returns the resolved path or exits non-zero.
deployment_path() {
    local root="${1:?root required}"
    local name="${2:?name required}"
    local resolved
    resolved="$(readlink -f -- "$root/$name" 2>/dev/null || printf '%s' "$root/$name")"
    case "$resolved" in
        "$root"*) ;;
        *) printf 'model: path escapes root: %s\n' "$resolved" >&2; return 1 ;;
    esac
    printf '%s\n' "$resolved"
}

# probe_df ROOT - print available free KB on the filesystem containing ROOT.
# Tests override this with a fixed output.
probe_df() {
    local root="${1:?root required}"
    clawdess_df -Pk "$root" 2>/dev/null || { printf 'disk: df failed for %s\n' "$root" >&2; return 1; }
}

# probe_curl - download URL to FILE with resume support.
# Tests override this with a fixed output.
probe_curl() {
    local url="${1:?url required}" output="${2:?output path required}"
    shift 2
    clawdess_curl --fail --location --continue-at - "$@" --output "$output" "$url"
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

json_write_atomic() {
    local path="${1:?path required}" payload="${2:?payload required}"
    local dir
    dir="$(dirname -- "$path")"
    mkdir -p -- "$dir"
    local tmp
    tmp="$(mktemp --tmpdir="$dir" "$(basename -- "$path").tmp.XXXXXX")" || return 1
    if ! json_atomic_write_temp "$tmp" "$payload"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! json_atomic_rename "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
}

json_atomic_write_temp() {
    local path="${1:?temp path required}" payload="${2:?payload required}"
    printf '%s\n' "$payload" >"$path"
}

json_atomic_rename() {
    mv -f -- "$1" "$2"
}

json_read() {
    local path="${1:?path required}"
    command python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' "$path"
}

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

initialize_layout() {
    local state_root="${1:?state root required}"
    mkdir -p -- "$state_root/state"
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

# State directory layout: state/ with files per phase.
# The wizard commits the layout atomically.

state_write() {
    local state_root="${1:?state root required}"
    local phase="${2:?phase required}"
    local reason="${3:?reason required}"
    local extra="${4:-}"

    local state_dir="$state_root/state"
    mkdir -p -- "$state_dir"

    # Read existing state if present
    local existing_state=""
    if [[ -f "$state_dir/deployment-state.json" ]]; then
        existing_state="$(json_read "$state_dir/deployment-state.json")"
    fi

    # Build combined state
    local payload
    if ! payload="$(command python3 -c "
import json, sys
existing = json.loads(sys.argv[1]) if sys.argv[1] else {}
state = {
    'state': 'failed' if 'failed' not in existing.get('state', '') else existing.get('state'),
    'phase': sys.argv[2],
    'error': sys.argv[3],
}
if existing:
    for k in ('models', 'venv', 'comfyui', 'tts'):
        if k in existing:
            state[k] = existing[k]
state['models'] = json.loads(sys.argv[4]) if sys.argv[4] else existing.get('models', [])
print(json.dumps(state, separators=(',',':')))
" "$existing_state" "$phase" "$(redact_text "$reason")" "$extra")"; then
        printf 'state: failed to construct JSON payload\n' >&2
        return 1
    fi
    json_write_atomic "$state_dir/deployment-state.json" "$payload"
}

state_success() {
    local state_root="${1:?state root required}"
    local state_dir="$state_root/state"
    local manifest_path="$state_root/deployment-manifest.json"

    mkdir -p -- "$state_dir"

    local existing_state=""
    if [[ -f "$state_dir/deployment-state.json" ]]; then
        existing_state="$(json_read "$state_dir/deployment-state.json")"
    fi

    local payload
    payload="$(command python3 -c "
import json, sys
existing = json.loads(sys.argv[1]) if sys.argv[1] else {}
manifest = {
    'state': 'completed',
    'phase': 'completed',
    'deployed_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}
for k in ('models', 'venv', 'comfyui', 'tts'):
    if k in existing:
        manifest[k] = existing[k]
print(json.dumps(manifest, separators=(',',':')))
" "$existing_state")"
    json_write_atomic "$manifest_path" "$payload"
}

# ---------------------------------------------------------------------------
# GPU / hardware checks
# ---------------------------------------------------------------------------

check_gb10_gpu() {
    local smi_output
    smi_output="$(clawdess_nvidia_smi --query-gpu=name,memory.total,compute.cap --format=csv,noheader 2>/dev/null)" || {
        printf 'gpu: nvidia-smi not available\n' >&2
        return 1
    }

    if [[ -z "$smi_output" ]]; then
        printf 'gpu: no GPU detected\n' >&2
        return 1
    fi

    local name memory_total compute_cap
    IFS=',' read -r name memory_total compute_cap <<< "$smi_output"

    # nvidia-smi's CSV formatter may surround each field with whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    memory_total="${memory_total#"${memory_total%%[![:space:]]*}"}"
    memory_total="${memory_total%"${memory_total##*[![:space:]]}"}"
    compute_cap="${compute_cap#"${compute_cap%%[![:space:]]*}"}"
    compute_cap="${compute_cap%"${compute_cap##*[![:space:]]}"}"

    if [[ "$name" != "GB10" ]]; then
        printf 'gpu: unexpected GPU %s (expected GB10)\n' "$name" >&2
        return 1
    fi

    # Validate memory: GB10 reports [N/A] which is not an integer.
    # Accept memory values that are numeric or contain "[N/A]".
    local mem_valid=false
    if [[ "$memory_total" =~ ^[0-9]+ ]]; then
        mem_valid=true
    elif [[ "$memory_total" == *"[N/A]"* ]]; then
        mem_valid=true
    fi

    if [[ "$compute_cap" != "12.1" ]]; then
        printf 'gpu: unexpected compute capability %s (expected 12.1 for GB10)\n' "$compute_cap" >&2
        return 1
    fi

    printf 'gpu: %s %s (compute %s)\n' "$name" "$memory_total" "$compute_cap"
    return 0
}

check_docker_socket() {
    if [[ -e /var/run/docker.sock ]]; then
        if command docker info >/dev/null 2>&1; then
            printf 'docker: socket accessible\n'
            return 0
        else
            printf 'docker: socket present but inaccessible\n'
            return 1
        fi
    else
        printf 'docker: socket not present\n'
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Python environment validation
# ---------------------------------------------------------------------------

validate_python_environment() {
    local venv_path="${1:?venv path required}"

    if [[ ! -d "$venv_path" ]]; then
        printf 'python: venv not found at %s\n' "$venv_path" >&2
        return 1
    fi

    local python_bin="$venv_path/bin/python"
    if [[ ! -x "$python_bin" ]]; then
        printf 'python: no executable at %s\n' "$python_bin" >&2
        return 1
    fi

    # Check exact interpreter path is absolute
    local interpreter_path
    interpreter_path="$(readlink -f -- "$python_bin")"
    case "$interpreter_path" in
        "$venv_path"/*) ;;
        *) printf 'python: interpreter %s not inside venv\n' "$interpreter_path" >&2; return 1 ;;
    esac

    # Check Python version
    local py_version
    py_version="$("$python_bin" --version 2>&1)" || { printf 'python: version check failed\n' >&2; return 1; }
    printf 'python: %s\n' "$py_version"

    # Check torch if available
    if "$python_bin" -c 'import torch; print(torch.__version__)' >/dev/null 2>&1; then
        printf 'torch: available\n'
    else
        printf 'torch: not installed (optional for minimal profile)\n'
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Model helpers
# ---------------------------------------------------------------------------

_model_path_safe() {
    local root="${1:?model root required}" filename="${2:?filename required}" candidate
    [[ "$filename" != /* && "$filename" != *..* && "$filename" != *$'\n'* && "$filename" != *$'\r'* ]] || return 1
    candidate=$(deployment_path "$root" "$filename") || return 1
    [[ "$(readlink -f -- "$(dirname -- "$candidate")" 2>/dev/null || dirname -- "$candidate")" == "$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")" ]] || return 1
    printf '%s\n' "$candidate"
}

_model_redact_url() {
    command python3 -c '
import re, sys
value = sys.argv[1]
value = re.sub(r"(https?://)[^/@\s]+@", r"\1<REDACTED>@", value)
value = re.sub(r"([?&](?:token|access_token|api_key|key)=)[^&\s]*", r"\1<REDACTED>", value)
print(value)
' "$1"
}

redact_text() {
    command python3 -c '
import os, pathlib, sys
value = sys.argv[1]
def secret_name(name):
    upper = name.upper()
    return any(x in upper for x in ("TOKEN", "SECRET", "API", "KEY", "PASSWORD")) and (upper.startswith("CLAWDESS_") or upper.endswith(("_TOKEN", "_SECRET", "_API_KEY", "_PASSWORD", "_TOKEN_FILE", "_TOKEN_PATH", "_SECRET_FILE", "_SECRET_PATH", "_API_KEY_FILE", "_API_KEY_PATH", "_PASSWORD_FILE", "_PASSWORD_PATH")))
for name, secret in os.environ.items():
    upper = name.upper()
    if not secret_name(name):
        continue
    if secret:
        value = value.replace(secret, "<REDACTED>")
    if upper.endswith(("_FILE", "_PATH")):
        try:
            file_value = pathlib.Path(secret).read_text().strip()
        except (OSError, ValueError):
            file_value = ""
        if file_value:
            value = value.replace(file_value, "<REDACTED>")
print(value)
' "$1"
}

_model_validate() {
    local path="${1:?path required}" minimum="${2:?minimum size required}" checksum="${3:-}" actual
    [[ -f "$path" && -r "$path" ]] || { printf 'model: file missing or unreadable: %s\n' "$path" >&2; return 1; }
    actual=$(stat -c '%s' -- "$path") || return 1
    [[ "$actual" =~ ^[0-9]+$ && "$actual" -ge "$minimum" ]] || { printf 'model: file below minimum size: %s\n' "$path" >&2; return 1; }
    if [[ -n "$checksum" ]]; then
        [[ "$checksum" == sha256:* ]] || { printf 'model: unsupported checksum format\n' >&2; return 1; }
        [[ "$(sha256sum -- "$path" | awk '{print $1}')" == "${checksum#sha256:}" ]] || { printf 'model: checksum mismatch: %s\n' "$path" >&2; return 1; }
    fi
    printf '%s\n' "$actual"
}

# model_records CONFIG IMAGE BACKEND - emit one JSON record per line from the config.
model_records() {
    local config="${1:?config required}" image="${2:?image required}" backend="${3:?backend required}"
    command python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
image = sys.argv[2]
backend = sys.argv[3]

image_entry = cfg.get(image, {})
backend_entry = cfg.get(backend, {})

records = []
if image_entry:
    r = {'kind': 'image', 'name': image}
    r.update(image_entry)
    records.append(json.dumps(r, separators=(',',':')))
if backend_entry:
    # Some backends have multiple files (e.g., piper has .onnx + .json)
    if 'files' in backend_entry:
        for fname, fmeta in backend_entry['files'].items():
            r = {'kind': 'tts', 'name': backend}
            r.update(fmeta)
            r['filename'] = fname
            records.append(json.dumps(r, separators=(',',':')))
    else:
        r = {'kind': 'tts', 'name': backend}
        r.update(backend_entry)
        records.append(json.dumps(r, separators=(',',':')))
print('\n'.join(records))
" "$config" "$image" "$backend"
}

# acquire_models ROOT CONFIG IMAGE BACKEND DRY_RUN STATE_ROOT
# Acquire all model records. On failure, persists state=failed.
acquire_models() {
    local root="${1:?model root required}" config="${2:?model config required}"
    local image="${3:?image model required}" backend="${4:?TTS backend required}"
    local dry_run="${5:-false}" state_root="${6:-}"

    local records=() record kind name source revision filename minimum required checksum path part size status checksum_status
    local free_kb free_bytes required_bytes state_models=""
    local -a model_entries=()
    local records_output
    records_output="$(model_records "$config" "$image" "$backend")" || return 1
    [[ -n "$records_output" ]] || { printf 'model: no selected records\n' >&2; return 1; }
    mapfile -t records <<< "$records_output"
    ((${#records[@]} > 0)) || { printf 'model: no selected records\n' >&2; return 1; }

    for record in "${records[@]}"; do
        [[ -n "$record" ]] || continue
        kind=$(_model_record_field "$record" kind)
        name=$(_model_record_field "$record" name)
        source=$(_model_record_field "$record" source)
        revision=$(_model_record_field "$record" revision)
        filename=$(_model_record_field "$record" filename)
        minimum=$(_model_record_field "$record" minimum_size_bytes)
        required=$(_model_record_field "$record" required)
        checksum=$(_model_record_field "$record" checksum)

        path=$(_model_path_safe "$root" "$filename") || {
            printf 'model: unsafe expected path: %s\n' "$filename" >&2
            return 1
        }
        part="$path.part"

        if [[ "$dry_run" == true ]]; then
            printf 'model planned: %s source=%s revision=%s path=%s\n' \
                "$kind" "$(_model_redact_url "$source")" "$revision" "$path"
            continue
        fi

        # Check existing file first
        if size=$(_model_validate "$path" "$minimum" "$checksum" 2>/dev/null); then
            status=valid
        else
            # Check disk space
            free_kb=$(probe_df -Pk "$root" 2>/dev/null | awk 'NR==2 {print $4}')
            required_bytes=$((minimum + 1048576))
            free_bytes=$((free_kb * 1024))
            if [[ "$free_kb" =~ ^[0-9]+$ && "$free_bytes" -ge "$required_bytes" ]]; then
                # Download
                mkdir -p -- "$(dirname -- "$path")" || return 1
                if ! probe_curl "$source" "$part" --fail --location --continue-at - >/dev/null 2>&1; then
                    rm -f -- "$part"
                    if [[ -n "$state_root" && "$required" == true ]]; then
                        local failed_record
                        failed_record=$(python3 -c "
import json, re, sys
r = json.loads(sys.argv[1])
r['source'] = re.sub(r'(https?://)[^/@\s]+@', r'\1<REDACTED>@', r.get('source', ''))
r.update(path=sys.argv[2], size=None, status='failed', checksum_status='not-declared')
print(json.dumps(r, separators=(',',':')))
" "$record" "$path")
                        state_models="\",\\\"models\\\": [$failed_record]"
                    fi
                    printf 'model: download failed for %s\n' "$filename" >&2
                    if [[ -n "$state_root" ]]; then
                        state_write "$state_root" "models" "download failed for $filename" "$state_models"
                    fi
                    return 1
                fi

                # Validate downloaded file
                if ! size=$(_model_validate "$part" "$minimum" "$checksum"); then
                    rm -f -- "$part"
                    if [[ -n "$state_root" && "$required" == true ]]; then
                        local failed_record
                        failed_record=$(python3 -c "
import json, re, sys
r = json.loads(sys.argv[1])
r['source'] = re.sub(r'(https?://)[^/@\s]+@', r'\1<REDACTED>@', r.get('source', ''))
r.update(path=sys.argv[2], size=None, status='failed', checksum_status='not-verified')
print(json.dumps(r, separators=(',',':')))
" "$record" "$path")
                        state_models="\",\\\"models\\\": [$failed_record]"
                    fi
                    printf 'model: validation failed for %s\n' "$filename" >&2
                    if [[ -n "$state_root" ]]; then
                        state_write "$state_root" "models" "validation failed for $filename" "$state_models"
                    fi
                    return 1
                fi

                # Atomic rename
                if ! mv -f -- "$part" "$path"; then
                    if [[ -n "$state_root" && "$required" == true ]]; then
                        local failed_record
                        failed_record=$(python3 -c "
import json, re, sys
r = json.loads(sys.argv[1])
r['source'] = re.sub(r'(https?://)[^/@\s]+@', r'\1<REDACTED>@', r.get('source', ''))
r.update(path=sys.argv[2], size=$size, status='failed', checksum_status='verified')
print(json.dumps(r, separators=(',',':')))
" "$record" "$path")
                        state_models="\",\\\"models\\\": [$failed_record]"
                    fi
                    printf 'model: finalization failed for %s\n' "$filename" >&2
                    if [[ -n "$state_root" ]]; then
                        state_write "$state_root" "models" "finalization failed for $filename" "$state_models"
                    fi
                    return 1
                fi
                status=downloaded
            else
                printf 'model: insufficient disk space for %s (need %d bytes, have %d KB)\n' \
                    "$filename" "$required_bytes" "${free_kb:-0}" >&2
                if [[ -n "$state_root" && "$required" == true ]]; then
                    state_models="\",\\\"models\\\": [{\"kind\":\"$kind\",\"name\":\"$name\",\"source\":\"$(_model_redact_url "$source")\",\"revision\":\"$revision\",\"filename\":\"$filename\",\"path\":\"$path\",\"size\":null,\"status\":\"failed\",\"checksum_status\":\"not-declared\"}]"
                fi
                if [[ -n "$state_root" ]]; then
                    state_write "$state_root" "models" "insufficient disk space" "$state_models"
                fi
                return 1
            fi
        fi

        # Record successful model state
        model_entries+=("$(python3 -c "
import json, sys, re
r = json.loads(sys.argv[1])
r['source'] = re.sub(r'(https?://)[^/@\s]+@', r'\1<REDACTED>@', r.get('source', ''))
r.update(path=sys.argv[2], size=int(sys.argv[3]), status=sys.argv[4], checksum_status=sys.argv[5])
print(json.dumps(r, separators=(',',':')))
" "$record" "$path" "$size" "$status" "${checksum:+verified:-not-declared}")")
    done

    # Write model state if we have entries
    if ((${#model_entries[@]} > 0)); then
        local models_json="["
        local first=true
        for entry in "${model_entries[@]}"; do
            if [[ "$first" == true ]]; then
                models_json+="$entry"
                first=false
            else
                models_json+=", $entry"
            fi
        done
        models_json+="]"
        if [[ -n "$state_root" ]]; then
            state_write "$state_root" "models" "model acquisition complete" "$models_json"
        fi
    fi

    return 0
}

_model_record_field() {
    local record="$1" field="$2"
    python3 -c "import json,sys; r=json.loads(sys.argv[1]); print(r.get(sys.argv[2],''))" "$record" "$field"
}

# ---------------------------------------------------------------------------
# ComfyUI helpers
# ---------------------------------------------------------------------------

# ComfyUI pinned revision metadata (immutable once set)
COMFYUI_REVISION="e6e0804c9dbea1cad1823527478b40f385ca6867"
COMFYUI_URL="https://github.com/comfyanonymous/ComfyUI"

install_comfyui() {
    local venv_python="${1:?venv python required}" comfyui_path="${2:?comfyui path required}"

    if [[ -d "$comfyui_path/.git" ]]; then
        local current_rev
        current_rev="$(git -C "$comfyui_path" rev-parse HEAD 2>/dev/null)" || true
        if [[ "$current_rev" == "$COMFYUI_REVISION" ]]; then
            printf 'comfyui: already installed at revision %s\n' "$COMFYUI_REVISION"
            return 0
        fi
        printf 'comfyui: updating from %s to %s\n' "$current_rev" "$COMFYUI_REVISION"
    fi

    if [[ ! -d "$comfyui_path/.git" ]]; then
        git clone --branch "$COMFYUI_REVISION" --depth 1 "$COMFYUI_URL" "$comfyui_path" || return 1
    else
        git -C "$comfyui_path" fetch --depth 1 origin "$COMFYUI_REVISION" || return 1
        git -C "$comfyui_path" checkout "$COMFYUI_REVISION" || return 1
    fi

    # Install required dependencies via pip (no GPU required for CPU inference)
    "$venv_python" -m pip install --no-cache-dir \
        --require-hashes \
        -r "$comfyui_path/requirements.txt" 2>&1 | tail -5 || {
        printf 'comfyui: dependency install failed\n' >&2
        return 1
    }

    printf 'comfyui: installed at revision %s\n' "$COMFYUI_REVISION"
    return 0
}

# ---------------------------------------------------------------------------
# TTS helpers
# ---------------------------------------------------------------------------

install_piper_tts() {
    local venv_python="${1:?venv python required}"

    # Piper is a Rust-based binary; install via pip
    "$venv_python" -m pip install --no-cache-dir piper-tts 2>&1 | tail -3 || {
        printf 'tts: piper install failed\n' >&2
        return 1
    }

    printf 'tts: piper installed\n'
    return 0
}

# ---------------------------------------------------------------------------
# Smoke test helpers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# smoke_test_comfyui — Starts ComfyUI, submits workflow, verifies output
# ---------------------------------------------------------------------------

# smoke_test_comfyui COMFYUI_PATH VENV_PYTHON DEPLOY_ROOT
# Starts ComfyUI in background on port 8188, waits for readiness,
# submits a minimal 4-node workflow, polls for completion, and verifies
# that an output image was produced.
# Returns 0 on success, 1 on failure.
smoke_test_comfyui() {
    local comfyui_path="${1:?comfyui path required}"
    local venv_python="${2:?venv python required}"
    local deploy_root="${3:?deploy root required}"

    # 1. Start ComfyUI in background on port 8188
    local comfyui_log="$deploy_root/logs/comfyui-smoke.log"
    local comfyui_pid_file="$deploy_root/run/comfyui.pid"
    mkdir -p -- "$deploy_root/logs" "$deploy_root/run"
    nohup "$venv_python" "$comfyui_path/main.py" --port 8188 > "$comfyui_log" 2>&1 &
    local comfyui_pid=$!
    printf '%s\n' "$comfyui_pid" > "$comfyui_pid_file"
    printf 'smoke: started ComfyUI (pid %d)\n' "$comfyui_pid"

    # 2. Wait for ComfyUI to become ready
    if ! wait_for_comfyui_readiness "http://127.0.0.1:8188" 60; then
        printf 'smoke: ComfyUI did not become ready\n' >&2
        kill "$comfyui_pid" 2>/dev/null || true
        return 1
    fi

    # 3. Submit a minimal workflow
    local workflow_json='{"prompt":{"1":{"class_type":"EmptyLatentImage","inputs":{"batch_size":1,"height":64,"width":64}},"2":{"class_type":"KSampler","inputs":{"model":[1],"positive":[3],"negative":[3],"latent_image":[1],"seed":42,"steps":2,"cfg":1}},"3":{"class_type":"VAEDecode","inputs":{"samples":[2],"vae":[1]}},"4":{"class_type":"SaveImage","inputs":{"filename_prefix":"smoke","images":[3]}}}}'
    local curl_output
    if ! curl_output=$(curl --fail --silent --max-time 30 -X POST "http://127.0.0.1:8188/prompt" -H 'Content-Type: application/json' -d "$workflow_json" 2>&1); then
        printf 'smoke: workflow submission failed: %s\n' "$curl_output" >&2
        kill "$comfyui_pid" 2>/dev/null || true
        return 1
    fi

    # Extract prompt_id from response
    local prompt_id
    prompt_id=$(printf '%s\n' "$curl_output" | python3 -c "import json,sys; print(json.load(sys.stdin).get('prompt_id',''))" 2>/dev/null)
    if [[ -z "$prompt_id" ]]; then
        printf 'smoke: no prompt_id in response\n' >&2
        kill "$comfyui_pid" 2>/dev/null || true
        return 1
    fi

    # Poll for completion via history endpoint
    local max_polls=30
    local i status
    for ((i=0; i<max_polls; i++)); do
        sleep 2
        local history_json
        history_json=$(curl --silent --max-time 10 "http://127.0.0.1:8188/history/$prompt_id" 2>/dev/null) || true
        if [[ -n "$history_json" ]]; then
            status=$(printf '%s\n' "$history_json" | python3 -c "
import json,sys
data = json.load(sys.stdin)
if '$prompt_id' in data:
    print(data['$prompt_id'].get('status',{}).get('status_str','pending'))
else:
    print('pending')
" 2>/dev/null)
            if [[ "$status" == "success" ]]; then
                break
            fi
            if [[ "$status" == "error" ]]; then
                printf 'smoke: workflow finished with error\n' >&2
                kill "$comfyui_pid" 2>/dev/null || true
                return 1
            fi
        fi
    done

    # 4. Verify output was produced
    local smoke_output="$deploy_root/artifacts/comfyui-output/images/smoke"
    local found_output
    found_output=$(ls "$smoke_output"/*.png "$smoke_output"/*.jpg "$smoke_output"/*.webp 2>/dev/null | head -1) || true
    if [[ -n "$found_output" ]]; then
        printf 'smoke: ComfyUI smoke test passed (workflow produced output)\n'
        kill "$comfyui_pid" 2>/dev/null || true
        return 0
    else
        printf 'smoke: ComfyUI smoke test failed (no output produced)\n' >&2
        kill "$comfyui_pid" 2>/dev/null || true
        return 1
    fi
}

smoke_test_piper() {
    local model_path=${1:?model path required}
    local deploy_root=${2:?deploy root required}

    # Validate model file exists
    if [[ ! -f "$model_path" ]]; then
        printf 'smoke: model not found: %s\n' "$model_path" >&2
        return 1
    fi

    local output_dir
    output_dir=$(mktemp -d -p "$deploy_root" "artifacts.XXXXXX")
    local output_file="${output_dir}/smoke_test.wav"

    # Attempt 1: direct --model invocation
    if piper --model "$model_path" --output "$output_file" <<< "Hello from Clawdess on DGX Spark." 2>/dev/null; then
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            printf 'smoke: piper generated %d bytes\n' "$output_file" >&2
            return 0
        fi
    fi

    # Attempt 2: with --config using the companion .json file
    local config_file="${model_path}.json"
    if [[ -f "$config_file" ]]; then
        if piper --model "$model_path" --config "$config_file" --output "$output_file" <<< "Hello from Clawdess on DGX Spark." 2>/dev/null; then
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                printf 'smoke: piper generated %d bytes (via config)\n' "$output_file" >&2
                return 0
            fi
        fi
    fi

    printf 'smoke: piper failed to generate audio\n' >&2
    return 1
}

# ---------------------------------------------------------------------------
# Readiness checks
# ---------------------------------------------------------------------------

# Wait until ComfyUI's /api/system_stats endpoint returns HTTP 200.
# Arguments: url timeout (seconds).
# Returns 0 when ready, 1 on timeout.
wait_for_comfyui_readiness() {
    local url=${1:?url required}
    local timeout=${2:-120}
    local elapsed=0
    while (( elapsed < timeout )); do
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "$url/api/system_stats" 2>/dev/null) || true
        if [[ "$http_code" == "200" ]]; then
            printf 'readiness: comfyui ready after %ds\n' "$elapsed"
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    printf 'readiness: comfyui not ready after %ds\n' "$timeout"
    return 1
}

# Wait until the piper binary is available on PATH.
# Argument: timeout (seconds).
# Returns 0 when ready, 1 on timeout.
wait_for_tts_ready() {
    local timeout=${1:-30}
    local elapsed=0
    while (( elapsed < timeout )); do
        if command -v piper >/dev/null 2>&1; then
            printf 'readiness: tts (piper) ready\n'
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    printf 'readiness: tts not ready after %ds\n' "$timeout"
    return 1
}

# ---------------------------------------------------------------------------
# Lifecycle script generation
# ---------------------------------------------------------------------------

generate_lifecycle_scripts() {
    local deploy_root="${1:?deploy root required}" state_root="${2:?state root required}"

    mkdir -p -- "$deploy_root/bin"

    # ComfyUI start script
    cat > "$deploy_root/bin/start-comfyui" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONUNBUFFERED=1
echo "Starting ComfyUI..."
"$SCRIPT_DIR/venv/bin/python" "$SCRIPT_DIR/artifacts/comfyui-runner.py" "$@"
echo "ComfyUI started"
SCRIPT

    # ComfyUI stop script
    cat > "$deploy_root/bin/stop-comfyui" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="$(dirname "$0")/../run/comfyui.pid"
if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f -- "$PID_FILE"
fi
echo "ComfyUI stopped"
SCRIPT

    # TTS start script
    cat > "$deploy_root/bin/start-tts" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Starting TTS service..."
"$SCRIPT_DIR/venv/bin/piper" "$@"
SCRIPT

    # TTS stop script
    cat > "$deploy_root/bin/stop-tts" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="$(dirname "$0")/../run/tts.pid"
if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f -- "$PID_FILE"
fi
echo "TTS stopped"
SCRIPT

    # Status script
    cat > "$deploy_root/bin/status" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "=== DGX Spark Deployment Status ==="
echo "Deploy root: $SCRIPT_DIR"
echo ""
if [[ -f "$SCRIPT_DIR/state/deployment-state.json" ]]; then
    echo "--- State ---"
    cat "$SCRIPT_DIR/state/deployment-state.json" | python3 -m json.tool
else
    echo "No deployment state found"
fi
echo ""
echo "--- Models ---"
if [[ -d "$SCRIPT_DIR/models" ]]; then
    find "$SCRIPT_DIR/models" -type f -exec ls -lh {} \; 2>/dev/null || echo "No models"
else
    echo "No models directory"
fi
SCRIPT

    chmod +x "$deploy_root/bin/"*.sh "$deploy_root/bin"/*.py "$deploy_root/bin"/start-* "$deploy_root/bin"/stop-* "$deploy_root/bin"/status 2>/dev/null || true

    printf 'lifecycle: generated scripts in %s/bin\n' "$deploy_root"
    return 0
}

# ---------------------------------------------------------------------------
# Systemd unit generation (optional)
# ---------------------------------------------------------------------------

generate_systemd_units() {
    local deploy_root="${1:?deploy root required}"

    mkdir -p -- ~/.config/systemd/user

    # ComfyUI service unit
    cat > "$HOME/.config/systemd/user/clawdess-comfyui.service" <<EOF
[Unit]
Description=Clawdess ComfyUI Service
After=network.target

[Service]
Type=simple
ExecStart=$deploy_root/bin/start-comfyui
ExecStop=$deploy_root/bin/stop-comfyui
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    # TTS service unit
    cat > "$HOME/.config/systemd/user/clawdess-tts.service" <<EOF
[Unit]
Description=Clawdess TTS Service
After=network.target

[Service]
Type=simple
ExecStart=$deploy_root/bin/start-tts
ExecStop=$deploy_root/bin/stop-tts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    printf 'systemd: generated units in ~/.config/systemd/user\n'
    return 0
}

# ---------------------------------------------------------------------------
# Failure state persistence
# ---------------------------------------------------------------------------

persist_failed_state() {
    local state_root="${1:?state root required}"
    local phase="${2:?phase required}"
    local error="${3:?error required}"

    state_write "$state_root" "$phase" "$(redact_text "$error")"
    printf 'state: persisted failed state for phase=%s\n' "$phase"
}

on_error() {
    local status="${1:?status required}" line="${2:?line required}" command_text="${3:-${BASH_COMMAND:-unknown}}"
    local message="phase=${PHASE:-unknown} status=${status} line=${line} command=${command_text}"
    message="$(redact_text "$message")"
    message="${message//\*\*\*/<REDACTED>}"
    printf '%s\n' "$message" >&2
    if [[ -n "${RUN_LOG:-}" ]]; then
        mkdir -p -- "$(dirname -- "$RUN_LOG")"
        printf '%s\n' "$message" >>"$RUN_LOG"
    fi
    if [[ -n "${STATE_ROOT:-}" ]]; then
        persist_failed_state "$STATE_ROOT" "${PHASE:-unknown}" "$message" || true
    fi
}

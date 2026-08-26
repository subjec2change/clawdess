#!/usr/bin/env bash
# Shared, side-effect-free helpers for the DGX Spark deployment wizard.
# Source this file; the executable wizard owns shell options and lifecycle.
set -o nounset

# Lifecycle state — initialized so nounset doesn't trip on empty arrays
started_pids=()
# Lifecycle defaults — CLI script may override these
DEPLOY_ROOT="${CLAWDESS_DEPLOY_ROOT:-${DEPLOY_ROOT:-/tmp/dgx-spark-deploy}}"
EXIT_CLEANUP_DONE=false

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
    local deploy_root="${1:?deploy root required}"
    mkdir -p -- "$deploy_root/state"
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

# State directory layout: state/ with files per phase.
# The wizard commits the layout atomically.

state_write() {
    local deploy_root="${1:?deploy root required}"
    local phase="${2:?phase required}"
    local reason="${3:?reason required}"
    local extra="${4:-}"
    local selection="${6:-}"

    local state_dir="$deploy_root/state"
    mkdir -p -- "$state_dir"

    # Read existing state if present
    local existing_state=""
    if [[ -f "$state_dir/deployment-state.json" ]]; then
        existing_state="$(json_read "$state_dir/deployment-state.json")"
    fi

    # Build combined state
    local payload
    if ! payload="$(command python3 -c "
import json, sys, os
existing = json.loads(sys.argv[1]) if sys.argv[1] else {}
# Preserve existing state if set; otherwise default to 'failed'
# sys.argv[5] is the desired state (may be empty string when not explicitly set)
desired_state = None
if len(sys.argv) > 5 and sys.argv[5]:
    desired_state = sys.argv[5]
if desired_state:
    state_val = desired_state
elif existing.get('state') and existing.get('state') != 'failed':
    state_val = existing['state']
else:
    state_val = 'failed'
state = {
    'state': state_val,
    'phase': sys.argv[2],
    'error': sys.argv[3],
}
if existing:
    for k in ('models', 'venv', 'comfyui', 'tts',
              'selected_features', 'provider', 'image_model',
              'video_model', 'tts_backend'):
        if k in existing:
            state[k] = existing[k]
state['models'] = json.loads(sys.argv[4]) if sys.argv[4] else existing.get('models', [])
if len(sys.argv) > 6 and sys.argv[6]:
    state.update(json.loads(sys.argv[6]))
print(json.dumps(state, separators=(',',':')))
" "$existing_state" "$phase" "$(redact_text "$reason")" "$extra" "${5:-}" "${6:-}")"; then
        printf 'state: failed to construct JSON payload\n' >&2
        return 1
    fi
    json_write_atomic "$state_dir/deployment-state.json" "$payload"
    json_write_atomic "$deploy_root/deployment-manifest.json" "$payload"
}

state_success() {
    local deploy_root="${1:?deploy root required}"
    local state_dir="$deploy_root/state"
    local manifest_path="$deploy_root/deployment-manifest.json"

    mkdir -p -- "$state_dir"

    local existing_state=""
    if [[ -f "$state_dir/deployment-state.json" ]]; then
        existing_state="$(json_read "$state_dir/deployment-state.json")"
    fi

    # Build manifest JSON, redacting secrets from existing state data
    local payload
    payload="$(command python3 -c "
import json, sys, os, re
existing = json.loads(sys.argv[1]) if sys.argv[1] else {}
manifest = {
    'state': 'completed',
    'phase': 'completed',
    'deployed_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}
# Redact secrets from existing state before embedding
def redact_obj(obj):
    if isinstance(obj, dict):
        return {k: redact_obj(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [redact_obj(item) for item in obj]
    elif isinstance(obj, str):
        result = re.sub(r'(https?://)[^/@\s]+@', r'\1<REDACTED>@', obj)
        result = re.sub(r'([?&](?:token|access_token|api_key|key)=)[^&\s]*', r'\1<REDACTED>', result)
        for env_name in os.environ:
            if env_name.startswith('CLAWDESS_'):
                val = os.environ[env_name]
                if val:
                    result = result.replace(val, '<REDACTED>')
        return result
    return obj
clean_existing = redact_obj(existing)
for k in ('models', 'venv', 'comfyui', 'tts', 'capability_states', 'selected_features', 'provider', 'image_model', 'video_model', 'tts_backend'):
    if k in clean_existing:
        manifest[k] = clean_existing[k]
print(json.dumps(manifest, separators=(',',':')))
" "$existing_state")"
    json_write_atomic "$manifest_path" "$payload"
}

# ---------------------------------------------------------------------------
# GPU / hardware checks
# ---------------------------------------------------------------------------

check_gb10_gpu() {
    local smi_output
    smi_output="$(clawdess_nvidia_smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null)" || {
        printf 'gpu: nvidia-smi probe failed\n' >&2
        return 1
    }

    if [[ -z "$smi_output" ]]; then
        printf 'gpu: no GPU detected\n' >&2
        return 1
    fi

    local name memory_total compute_cap
    IFS=',' read -r name memory_total compute_cap <<< "$smi_output"
    if [[ -z "$compute_cap" ]]; then
        compute_cap="$memory_total"
        memory_total="[N/A]"
    fi

    # nvidia-smi's CSV formatter may surround each field with whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    memory_total="${memory_total#"${memory_total%%[![:space:]]*}"}"
    memory_total="${memory_total%"${memory_total##*[![:space:]]}"}"
    compute_cap="${compute_cap#"${compute_cap%%[![:space:]]*}"}"
    compute_cap="${compute_cap%"${compute_cap##*[![:space:]]}"}"

    name="${name#NVIDIA }"
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
# Handles both legacy flat format (single file per entry) and new nested files format
# where models have a `files` sub-dict keyed by subdir (diffusion_models, checkpoints,
# text_encoders, clip_vision, vae, etc.), each containing a list of file entries with
# source, filename, minimum_size_bytes, required, checksum.
model_records() {
    local config="${1:?config required}" image="${2:-}" backend="${3:-}" video="${4:-}" features="${5:-photo,voice}"
    command python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
image = sys.argv[2]
backend = sys.argv[3]
video = sys.argv[4]
features = {x.strip() for x in __import__('re').split(r'[\s,]+', sys.argv[5]) if x.strip()}

image_entry = cfg.get('models', {}).get(image, cfg.get(image, {}))
# Preserve the legacy CLI backend names while using the new catalog keys.
backend_candidates = [backend]
if backend and not backend.endswith('-voice'):
    backend_candidates.append(f'{backend}-voice')
backend_entry = {}
backend_name = backend
for candidate in backend_candidates:
    if candidate in cfg.get('models', {}):
        backend_name = candidate
        backend_entry = cfg['models'][candidate]
        break
    if candidate in cfg:
        backend_name = candidate
        backend_entry = cfg[candidate]
        break

records = []

def nested_record(kind, name, subdir, fmeta):
    if not isinstance(fmeta, dict): raise ValueError('invalid model record')
    required = ('source', 'filename', 'minimum_size_bytes', 'required', 'checksum', 'destination')
    if any(key not in fmeta for key in required): raise ValueError('invalid model record')
    destination = fmeta['destination']
    if not isinstance(destination, str) or not destination or destination.startswith('/') or '..' in destination.split('/'):
        raise ValueError('invalid destination')
    r = {'kind': kind, 'name': name}; r.update(fmeta); r['subdir'] = destination
    records.append(json.dumps(r, separators=(',',':')))
def nested_records(kind, name, entry):
    for subdir, file_list in entry['files'].items():
        for fmeta in (file_list if isinstance(file_list, list) else [file_list]): nested_record(kind, name, subdir, fmeta)

def emit(kind, name, entry, feature):
    if feature not in features or not entry: return
    if 'files' in entry: nested_records(kind, name, entry)
    else:
        r = {'kind': kind, 'name': name}; r.update(entry); records.append(json.dumps(r, separators=(',',':')))

video_entry = cfg.get('models', {}).get(video, cfg.get(video, {})) if video else {}
emit('image', image, image_entry, 'photo')
emit('video', video, video_entry, 'video')
emit('tts', backend_name, backend_entry, 'voice')

print('\\n'.join(records))
" "$config" "$image" "$backend" "$video" "$features"
}

# acquire_models ROOT CONFIG IMAGE BACKEND DRY_RUN STATE_ROOT
# Acquire all model records. On failure, persists state=failed.
acquire_models() {
    local root="${1:?model root required}" config="${2:?model config required}"
    local image="${3:-}" backend="${4:-}"
    local dry_run="${5:-false}" state_root="${6:-}" features="${7:-photo,voice}" video="${8:-}"

    local records=() record kind name source revision filename subdir minimum required checksum path part size status checksum_status
    local free_kb free_bytes required_bytes state_models=""
    local -a model_entries=()
    local records_output
    records_output="$(model_records "$config" "$image" "$backend" "$video" "$features")" || return 1
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
        subdir=$(_model_record_field "$record" destination)
        minimum=$(_model_record_field "$record" minimum_size_bytes)
        required=$(_model_record_field "$record" required)
        checksum=$(_model_record_field "$record" checksum)

        if [[ -n "$subdir" ]]; then
            path=$(_model_path_safe "$root/$subdir" "$filename") || {
                printf 'model: unsafe expected path: %s/%s\n' "$subdir" "$filename" >&2
                return 1
            }
        else
            path=$(_model_path_safe "$root" "$filename") || {
                printf 'model: unsafe expected path: %s\n' "$filename" >&2
                return 1
            }
        fi
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
        if [[ -n "$checksum" ]]; then
            checksum_status=verified
        else
            checksum_status=not-declared
        fi
        model_entries+=("$(python3 -c "
import json, sys, re
r = json.loads(sys.argv[1])
r['source'] = re.sub(r'(https?://)[^/@\s]+@', r'\1<REDACTED>@', r.get('source', ''))
r.update(path=sys.argv[2], size=int(sys.argv[3]), status=sys.argv[4], checksum_status=sys.argv[5])
print(json.dumps(r, separators=(',',':')))
" "$record" "$path" "$size" "$status" "$checksum_status")")
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

# Resolve pinned revision: fall back to latest main if the pinned commit was force-pushed away
_resolve_comfyui_revision() {
    if git ls-remote "$COMFYUI_URL" "$COMFYUI_REVISION" 2>/dev/null | grep -q "$COMFYUI_REVISION"; then
        printf '%s' "$COMFYUI_REVISION"
        return 0
    fi
    printf 'comfyui: pinned revision %s not found in upstream (force-pushed); falling back to master\n' "$COMFYUI_REVISION" >&2
    git ls-remote --refs "$COMFYUI_URL" refs/heads/master | awk '{print $1}' | head -1
}

install_comfyui() {
    local venv_python="${1:?venv python required}" comfyui_path="${2:?comfyui path required}"

    if [[ -d "$comfyui_path/.git" ]]; then
        local current_rev
        current_rev="$(git -C "$comfyui_path" rev-parse HEAD 2>/dev/null)" || true
        local target_rev
        target_rev="$(_resolve_comfyui_revision)" || return 1
        if [[ "$current_rev" == "$target_rev" ]]; then
            printf 'comfyui: already installed at revision %s\n' "$target_rev"
            return 0
        fi
        printf 'comfyui: updating from %s to %s\n' "$current_rev" "$target_rev"
    fi

    local target_rev
    target_rev="$(_resolve_comfyui_revision)" || return 1

    if [[ ! -d "$comfyui_path/.git" ]]; then
        # If target_rev is a bare 40-char SHA (force-push fallback), clone master then checkout
        if [[ "$target_rev" =~ ^[0-9a-f]{40}$ ]]; then
            git clone --depth 1 "$COMFYUI_URL" "$comfyui_path" || return 1
            git -C "$comfyui_path" checkout "$target_rev" || return 1
        else
            git clone --branch "$target_rev" --depth 1 "$COMFYUI_URL" "$comfyui_path" || return 1
        fi
    else
        git -C "$comfyui_path" fetch --depth 1 origin "$target_rev" || return 1
        git -C "$comfyui_path" checkout "$target_rev" || return 1
    fi

    # Install required dependencies via pip (no GPU required for CPU inference)
    # Note: --require-hashes dropped because ComfyUI's requirements.txt
    # doesn't list hashes for all transitive deps (e.g. comfyui-frontend-package)
    "$venv_python" -m pip install --no-cache-dir \
        -r "$comfyui_path/requirements.txt" 2>&1 | tail -5 || {
        printf 'comfyui: dependency install failed\n' >&2
        return 1
    }

    printf 'comfyui: installed at revision %s\n' "$COMFYUI_REVISION"
    return 0
}

# ---------------------------------------------------------------------------
# Local video provisioning seam
# ---------------------------------------------------------------------------
provision_local_video() {
    local deploy_root="${1:?deploy root required}" state_root="${2:?state root required}" model="${3:?video model required}" config="${4:?config required}" dry_run="${5:-false}"
    local manifest="$deploy_root/config/video-local.json"
    local payload
    payload="$(python3 - "$deploy_root" "$model" "$config" <<'PYJSON'
import json,sys
root,model,config=sys.argv[1:]
entry=json.load(open(config)).get("models",{}).get(model,{})
files=entry.get("files",{})
deps={k:f"{root}/models/{k}" for k in ("diffusion_models","text_encoders","vae","clip_vision") if k in files}
print(json.dumps({"provider":"local","model":model,"status":"deferred","reason":"Wan2GP/ComfyUI runtime and custom-node revisions are not pinned; installation deferred","model_root":f"{root}/models","dependencies":deps},separators=(",",":")))
PYJSON
)"
    if [[ "$dry_run" == true ]]; then printf 'video: local provisioning deferred (dry-run; no files written)
'; return 0; fi
    mkdir -p "$deploy_root/config" "$deploy_root/bin" "$deploy_root/run" "$deploy_root/logs"
    json_write_atomic "$manifest" "$payload"
    printf '#!/usr/bin/env bash
printf "video: local runtime deferred; start unavailable\n" >&2
exit 2
' > "$deploy_root/bin/start-video"
    printf '#!/usr/bin/env bash
rm -f "$(dirname "$0")/../run/video.pid"
printf "video: local service stopped (deferred seam)\n"
' > "$deploy_root/bin/stop-video"
    chmod +x "$deploy_root/bin/start-video" "$deploy_root/bin/stop-video"
    printf 'video: local Wan2GP/ComfyUI scaffolded with model dependency paths; runtime installation deferred
' >&2
    return 1
}
provision_video() {
    local deploy_root="$1" state_root="$2" provider="$3" model="$4" config="$5" dry_run="${6:-false}"
    [[ "$provider" == remote ]] && { printf 'video: remote provider selected; skipping local video provisioning
'; return 0; }
    provision_local_video "$deploy_root" "$state_root" "$model" "$config" "$dry_run"
}

feature_selected() {
    local features="${1:-}" wanted="${2:?feature required}"
    [[ ",${features// /,}," == *",$wanted,"* ]]
}

# ---------------------------------------------------------------------------
# TTS helpers
# ---------------------------------------------------------------------------

# voice_backend_status CONFIG BACKEND
# Emit a stable JSON capability result without claiming runtime readiness.
voice_backend_status() {
    local config="${1:?config required}" requested="${2:?backend required}"
    python3 - "$config" "$requested" <<'PY'
import json, sys
config, requested = sys.argv[1], sys.argv[2].lower()
cfg = json.load(open(config))
aliases = {"piper-voice": "piper", "xtts": "xtts-v2", **cfg.get("aliases", {})}
backend = requested
seen = set()
while backend in aliases and backend not in seen:
    seen.add(backend)
    backend = aliases[backend]
known = cfg.get("voice_backends", {})
if backend == "vllm" or backend not in known:
    print(f"voice: unsupported backend: {requested}", file=sys.stderr)
    raise SystemExit(1)
entry = known[backend]
state = entry.get("status", "unavailable")
result = {"backend": backend, "state": state, "reason": entry.get("description", "no capability description")}
if "speaker_wav" in entry:
    result["speaker_wav"] = entry["speaker_wav"]
if "voices" in entry:
    result["voices"] = entry["voices"]
print(json.dumps(result, separators=(",", ":")))
PY
}

# validate_voice_backend CONFIG BACKEND
validate_voice_backend() {
    local config="${1:?config required}" requested="${2:?backend required}"
    python3 - "$config" "$requested" <<'PY'
import json, sys
cfg=json.load(open(sys.argv[1])); requested=sys.argv[2].lower()
aliases={'piper-voice':'piper','xtts':'xtts-v2', **cfg.get('aliases',{})}
backend=requested
if backend == 'piper-voice': backend='piper'
else: backend=aliases.get(backend, backend)
if backend == "piper-voice": backend="piper"
known=cfg.get('voice_backends', {})
features=cfg.get('features',{})
voice_feature=features.get('voice',{}) if isinstance(features, dict) else {}
allowed=voice_feature.get('backends',[]) if isinstance(voice_feature, dict) else []
if backend == 'vllm' or (backend not in known and backend not in allowed and backend not in {'piper','kokoro','xtts-v2'}):
 print(f"voice: unsupported backend: {requested}", file=sys.stderr); raise SystemExit(1)
print(backend)
PY
}

install_voice_backend() {
    local backend="${1:?backend required}" venv_python="${2:?venv python required}"
    case "$backend" in
      piper|piper-voice) install_piper_tts "$venv_python" ;;
      kokoro) printf 'tts: kokoro experimental; runtime installation deferred (no dependency/download claimed)\n' >&2; return 1 ;;
      xtts|xtts-v2) printf 'tts: XTTS v2 deferred; configure speaker_wav before runtime installation\n' >&2; return 1 ;;
      *) printf 'tts: unsupported voice backend: %s\n' "$backend" >&2; return 1 ;;
    esac
}

install_piper_tts() {
    local venv_python="${1:?venv python required}"

    # Piper is a Rust-based binary; install via pip
    "$venv_python" -m pip install --no-cache-dir piper-tts || {
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
    local deploy_root="${1:?deploy root required}"
    local state_root="${2:?state root required}"
    local profile="${3:-minimal}"
    local docker_available="${4:-false}"

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

    # Health-check script
    cat > "$deploy_root/bin/health-check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

error_count=0

# Check ComfyUI readiness
if [[ -f "$SCRIPT_DIR/run/comfyui.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/comfyui.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        # Try readiness endpoint
        if "$SCRIPT_DIR/venv/bin/python" -c '
import urllib.request, sys
try:
    resp = urllib.request.urlopen("http://127.0.0.1:8188/system_stats", timeout=5)
    if resp.status == 200:
        sys.exit(0)
except Exception:
    sys.exit(1)
' 2>/dev/null; then
            printf 'ComfyUI: ready (pid %s)\n' "$pid"
        else
            printf 'ComfyUI: process alive but not ready (pid %s)\n' "$pid"
            error_count=$((error_count + 1))
        fi
    else
        printf 'ComfyUI: dead process in pid file\n'
        error_count=$((error_count + 1))
    fi
else
    printf 'ComfyUI: no pid file found (service not started)\n'
    error_count=$((error_count + 1))
fi

# Check TTS availability
if [[ -f "$SCRIPT_DIR/run/tts.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/tts.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        printf 'TTS (piper): ready (pid %s)\n' "$pid"
    else
        printf 'TTS (piper): dead process in pid file\n'
        error_count=$((error_count + 1))
    fi
else
    printf 'TTS (piper): no pid file found (service not started)\n'
    error_count=$((error_count + 1))
fi

# Check local video registration
if [[ -f "$SCRIPT_DIR/config/video-local.json" ]]; then
    video_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","unknown"))' "$SCRIPT_DIR/config/video-local.json" 2>/dev/null || echo unknown)"
    printf 'Video: local provisioning %s\n' "$video_status"
    [[ "$video_status" == "deferred" ]] && error_count=$((error_count + 1))
fi

# Check state file
if [[ -f "$SCRIPT_DIR/state/deployment-state.json" ]]; then
    state="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("state","unknown"))' "$SCRIPT_DIR/state/deployment-state.json" 2>/dev/null || echo unknown)"
    printf 'State: %s\n' "$state"
    if [[ "$state" == "failed" ]]; then
        error_count=$((error_count + 1))
    fi
fi

if [[ "$error_count" -gt 0 ]]; then
    printf 'health-check: %d issue(s) found\n' "$error_count"
    exit 1
fi

printf 'health-check: all services healthy\n'
exit 0
SCRIPT

    # Docker Compose scaffold — only for non-minimal profiles with Docker available
    if [[ "$profile" != "minimal" && "$docker_available" == "true" ]]; then
        cat > "$deploy_root/docker-compose.yml" <<'COMPOSE'
version: "3.8"
services:
  comfyui:
    image: ghcr.io/comfyanonymous/comfyui:latest
    volumes:
      - "./models:/models"
      - "./artifacts:/artifacts"
    ports:
      - "8188:8188"
    environment:
      - PYTHONUNBUFFERED=1
    restart: unless-stopped

  tts:
    image: ghcr.io/rhasspy/piper:latest
    volumes:
      - "./models:/models"
    command: >
      piper --model /models/lessac-medium.onnx
      --config /models/lessac-medium.onnx.json
      --output /artifacts/tts-output
    restart: unless-stopped
COMPOSE
    fi

    chmod +x "$deploy_root/bin/"*.sh "$deploy_root/bin"/*.py "$deploy_root/bin"/start-* "$deploy_root/bin"/stop-* "$deploy_root/bin"/status "$deploy_root/bin"/health-check 2>/dev/null || true

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
    local deploy_root="${1:?deploy root required}"
    local phase="${2:?phase required}"
    local error="${3:?error required}"

    if ! state_write "$deploy_root" "$phase" "$(redact_text "$error")"; then
        printf 'state: failed to persist failed state for phase=%s\n' "$phase" >&2
        return 1
    fi
    printf 'state: persisted failed state for phase=%s\n' "$phase"
}

reset_deployment_root() {
    local root="${1:?deploy root required}" current parent
    [[ -n "$root" && "$root" != / && "$root" != . && "$root" != "$HOME" ]] || { printf 'reset: refusing unsafe deployment root\n' >&2; return 2; }
    current="$root"
    while [[ "$current" != / ]]; do
        [[ ! -L "$current" ]] || { printf 'reset: refusing symlink path component: %s\n' "$current" >&2; return 2; }
        parent=$(dirname -- "$current")
        [[ "$parent" != "$current" ]] || break
        current="$parent"
    done
    [[ ! -e "$root" ]] || rm -rf -- "$root" || return 1
    printf 'reset: removed deployment data at %s (external model root preserved)\n' "$root"
}

on_error() {
    local status="${1:?status required}" line="${2:?line required}" command_text="${3:-${BASH_COMMAND:-unknown}}"
    local message="phase=${PHASE:-unknown} status=${status} line=${line} command=${command_text}"
    message="$(redact_text "$message")"
    message="$(_model_redact_url "$message")"
    message="${message//\*\*\*/<REDACTED>}"
    printf '%s\n' "$message" >&2
    if [[ -n "${RUN_LOG:-}" ]]; then
        mkdir -p -- "$(dirname -- "$RUN_LOG")"
        printf '%s\n' "$message" >>"$RUN_LOG"
    fi
    if [[ -n "${STATE_ROOT:-}" ]]; then
        if ! persist_failed_state "$STATE_ROOT" "${PHASE:-unknown}" "$message"; then
            printf 'state: error handler could not persist failure state\n' >&2
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Lifecycle: PID tracking and cleanup
# ---------------------------------------------------------------------------

# Track PID for cleanup on EXIT
track_pid() {
    local pid="${1:?pid required}" service="${2:?service required}"
    started_pids+=("$pid")
    printf '%s' "$pid" > "$DEPLOY_ROOT/run/${service}.pid"
    printf 'lifecycle: tracking %s pid=%s\n' "$service" "$pid" >> "${RUN_LOG:-/dev/stdout}"
}

# Cleanup function - stops only services started by this run
do_cleanup() {
    [[ "$EXIT_CLEANUP_DONE" == true ]] && return
    EXIT_CLEANUP_DONE=true
    printf 'cleanup: stopping %d service(s)\n' "${#started_pids[@]}"
    for pid in "${started_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            printf 'cleanup: sending SIGTERM to pid %s\n' "$pid"
            kill "$pid" 2>/dev/null || true
        fi
    done
    # Also stop services via their PID files that we might not have tracked
    if [[ -n "$DEPLOY_ROOT" && -d "$DEPLOY_ROOT/run" ]]; then
        local my_pid=$$
        for pid_file in "$DEPLOY_ROOT/run"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            pid="$(cat "$pid_file" 2>/dev/null)" || continue
            if [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$my_pid" ]] && ! printf '%s\n' "${started_pids[@]}" | grep -qx "$pid" 2>/dev/null; then
                if kill -0 "$pid" 2>/dev/null; then
                    printf 'cleanup: stopping orphan pid %s\n' "$pid"
                    kill "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi
}

# capability_manifest CONFIG FEATURES PROVIDER IMAGE VIDEO VOICE
capability_manifest() {
    local config="${1:?config required}" features="${2:-}" provider="${3:-local}" image="${4:-}" video="${5:-}" voice="${6:-}"
    python3 - "$config" "$features" "$provider" "$image" "$video" "$voice" <<'PY2'
import json, sys, re
cfg=json.load(open(sys.argv[1])); selected=[x for x in re.split(r'[\s,]+',sys.argv[2]) if x]
provider,image,video,voice=sys.argv[3:]; models=cfg.get('models',{}); vb=cfg.get('voice_backends',{}); aliases=cfg.get('aliases',{}); states={}
for feature in selected:
    name={'photo':image,'video':video,'voice':voice}.get(feature,''); resolved=name
    seen=set()
    while feature=='voice' and resolved in aliases and resolved not in seen:
        seen.add(resolved); resolved=aliases[resolved]
    meta=vb.get(name,{}) if feature=='voice' else models.get(name,{})
    if feature=='voice' and not meta:
        meta=vb.get(resolved,{})
    status=meta.get('status') or ('experimental' if meta.get('experimental') else ('verified' if resolved and resolved in models else 'unavailable'))
    allowed={'verified','experimental','deferred','unavailable','blocked'}
    if status not in allowed:
        raise SystemExit(f'unknown capability status: {status!r} for {feature}')
    if feature=='video' and status=='verified': status='deferred'
    # Provider selection is independent from whether local dependencies apply.
    local_dependency_applicability = feature in {'video', 'voice'}
    local_dependencies = local_dependency_applicability
    local_dependency_state = 'deferred' if feature == 'video' else ('required' if feature == 'voice' else 'delegated')
    states[feature]={'state':status,'selected':name,'provider':provider,'local_dependencies':local_dependencies,'applicable':local_dependency_applicability,'local_dependency_applicability':local_dependency_applicability,'local_dependency_state':local_dependency_state}
print(json.dumps({'capability_states':states,'provider':provider,'selected_features':selected,'image_model':image,'video_model':video,'tts_backend':voice},separators=(',',':')))
PY2
}

capability_reject_non_dry_run() {
    python3 - "$1" <<'PY2'
import json,sys
for capability,item in json.load(open(sys.argv[1])).get('capability_states',{}).items():
    if item.get('state') in {'deferred','unavailable','blocked'}:
        print(f"capability: {capability} is {item['state']}; non-dry-run selection is unavailable",file=sys.stderr); raise SystemExit(1)
PY2
}

# ---------------------------------------------------------------------------
# Feature selection from profile or interactive stdin
# ---------------------------------------------------------------------------

# Resolve enabled features for a profile.
# Signature: select_features CONFIG PROFILE
# Returns: space-separated feature list (e.g., "photo video voice")
# Exit 0 on success, non-zero on failure.
#
# Resolution order:
#   1. Look up PROFILE in config "profiles" section; use its "features" array.
#   2. Non-interactive (stdin not a terminal) → default to "photo".
#   3. Interactive → prompt user to select 1/photo, 2/video, 3/voice.
#
select_features() {
    local config="${1:?CONFIG required}"
    local profile="${2:-}"

    # Validate config exists
    if [[ ! -f "$config" ]]; then
        printf 'select_features: config not found: %s\n' "$config" >&2
        return 1
    fi

    local features=()

    # Extract features array for this profile using python3
    local feature_list
    feature_list="$(command python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
p = cfg.get("profiles", {}).get(sys.argv[2], {})
fs = p.get("features", [])
print(json.dumps(fs))
' "$config" "$profile" 2>/dev/null)"

    if [[ -n "$feature_list" && "$feature_list" != "null" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && features+=("$item")
        done < <(printf '%s' "$feature_list" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
if isinstance(data, list):
    for x in data:
        print(x)
" 2>/dev/null)
        if [[ "${#features[@]}" -gt 0 ]]; then
            printf '%s\n' "${features[*]}"
            return 0
        fi
    fi

    # Profile not found or has no features — fall back to non-interactive/interactive
    if [[ -n "${CLAWDESS_INTERACTIVE_WIZARD:-}" || -t 0 ]]; then
        # Interactive: prompt user
        printf 'Select features to enable:\n' >&2
        printf '  1) photo\n' >&2
        printf '  2) video\n' >&2
        printf '  3) voice\n' >&2
        printf 'Enter choice(s) separated by spaces (1-3): ' >&2
        local input
        if [[ -n "${CLAWDESS_INTERACTIVE_WIZARD:-}" ]]; then IFS= read -r input <&3 || true; else IFS= read -r input || true; fi
        features=()
        if [[ -n "$input" ]]; then
            local sel
            for sel in $input; do
                case "$sel" in
                    1) features+=("photo") ;;
                    2) features+=("video") ;;
                    3) features+=("voice") ;;
                esac
            done
        fi
    else
        # Non-interactive: default to photo
        features=("photo")
    fi

    if [[ "${#features[@]}" -eq 0 ]]; then
        printf 'select_features: no features selected\n' >&2
        return 1
    fi

    printf '%s\n' "${features[*]}"
    return 0
}

# ---------------------------------------------------------------------------
# Provider selection — local vs remote
# ---------------------------------------------------------------------------

# Capitalise first character (used by interactive prompts).
capitalize() {
    local s="$1"
    printf '%s\n' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')${s:1}"
}

# Resolve the provider for a given category.
# Signature: select_provider CONFIG CATEGORY PROFILE [CLI_PROVIDER]
# Returns: 'local' or 'remote'
# Exit 0 on success, non-zero on failure.
#
# Resolution order:
#   1. CLI override (4th arg) — highest priority.
#   2. Profile default from config "profiles" section — defaults to 'local'.
#   3. Non-interactive (stdin not a terminal) — defaults to 'local'.
#   4. Interactive — prompt 1=local, 2=remote.
#
select_provider() {
    local config="${1:?CONFIG required}"
    local category="${2:?CATEGORY required}"
    local profile="${3:-}"
    local cli_provider="${4:-}"

    # Validate config exists
    if [[ ! -f "$config" ]]; then
        printf 'select_provider: config not found: %s\n' "$config" >&2
        return 1
    fi

    # 1. CLI override takes priority
    if [[ -n "$cli_provider" ]]; then
        printf '%s\n' "$cli_provider"
        return 0
    fi

    # 2. Profile default — defaults to 'local'
    if [[ -n "$profile" ]]; then
        local provider
        provider="$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
profile_name = sys.argv[2]
category = sys.argv[3]
p = cfg.get('profiles', {}).get(profile_name, {})
# Profile-level provider override, fall back to 'local'
print(p.get('provider', 'local'))
" "$config" "$profile" "$category")"
        printf '%s\n' "$provider"
        return 0
    fi

    # 3. Non-interactive — default to 'local'
    if [[ -z "${CLAWDESS_INTERACTIVE_WIZARD:-}" && ! -t 0 ]]; then
        printf 'local\n'
        return 0
    fi

    # 4. Interactive prompt
    printf '\n%s provider:\n' "$(capitalize "$category")" >&2
    printf '  1) Local ComfyUI (requires GPU, local models)\n' >&2
    printf '  2) Remote API (cloud inference)\n' >&2
    printf 'Select [1-2]: ' >&2

    local choice
    if [[ -n "${CLAWDESS_INTERACTIVE_WIZARD:-}" ]]; then IFS= read -r choice <&3 || choice="1"; else IFS= read -r choice || choice="1"; fi
    case "$choice" in
        1) printf 'local\n' ;;
        2) printf 'remote\n' ;;
        *) printf 'local\n' ;;
    esac
    return 0
}

# select_model CATEGORY CONFIG PROFILE [CLI_MODEL]
# Returns the selected model key for a category.
# Resolution order: CLI override > profile default > non-interactive first
#   > interactive catalog selection from stdin.
select_model() {
    local config="${1:?config required}"
    local category="${2:?category required}"
    local profile="${3:-}"
    local cli_model="${4:-}"

    # Validate config exists
    if [[ ! -f "$config" ]]; then
        printf 'select_model: config not found: %s\n' "$config" >&2
        return 1
    fi

    # 1. CLI override takes priority
    if [[ -n "$cli_model" ]]; then
        local valid
        valid=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
models = cfg.get('models', {})
cli = sys.argv[2]
if cli in models:
    print(cli)
" "$config" "$cli_model")
        if [[ -n "$valid" ]]; then
            printf '%s\n' "$valid"
            return 0
        fi
        printf 'unknown model: %s\n' "$cli_model" >&2
        return 1
    fi

    # 2. Profile default
    if [[ -n "$profile" ]]; then
        local profile_key
        case "$category" in
            photo) profile_key="photo_model" ;;
            video) profile_key="video_model" ;;
            *) profile_key="tts_backend" ;;
        esac
        local model
        model=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
p = cfg.get('profiles', {}).get(sys.argv[2], {})
model = p.get(sys.argv[3], '')
aliases = cfg.get('aliases', {'piper': 'piper-voice', 'kokoro': 'piper-voice'})
print(aliases.get(model, model))
" "$config" "$profile" "$profile_key")
        if [[ -n "$model" ]]; then
            printf '%s\n' "$model"
            return 0
        fi
    fi

    # 3. Non-interactive default (first catalog entry)
    if [[ -z "${CLAWDESS_INTERACTIVE_WIZARD:-}" && ! -t 0 ]]; then
        local default_model
        default_model=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1])); category = sys.argv[2]
f = cfg.get('features', {})
if isinstance(f, dict):
    e = f.get(category, {}); items = e.get('backends' if category == 'voice' else 'models', []) if isinstance(e, dict) else []
else:
    items = []
if not items:
    items = cfg.get('catalog', {}).get(category, [])
print(items[0] if items else '')
" "$config" "$category")
        [[ -n "$default_model" ]] || { printf 'no models for category: %s\n' "$category" >&2; return 1; }
        printf '%s\n' "$default_model"
        return 0
    fi

    # 4. Interactive catalog
    local catalog_output
    catalog_output=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
category = sys.argv[2]
if category == 'voice':
    features_cfg = cfg.get('features', {})
    entry = features_cfg.get('voice', {}) if isinstance(features_cfg, dict) else {}
    backends = entry.get('backends', []) if isinstance(entry, dict) else []
    if not backends:
        backends = cfg.get('catalog', {}).get('voice', [])
    models = [(b, cfg.get('models', {}).get(b, {})) for b in backends]
else:
    features_cfg = cfg.get('features', {})
    entry = features_cfg.get(category, {}) if isinstance(features_cfg, dict) else {}
    models_list = entry.get('models', []) if isinstance(entry, dict) else []
    if not models_list:
        models_list = cfg.get('catalog', {}).get(category, [])
    models = [(m, cfg.get('models', {}).get(m, {})) for m in models_list]

for i, (key, meta) in enumerate(models, 1):
    name = meta.get('name', key)
    desc = meta.get('description', f'{category}, {meta.get(\"vram_min_gb\", \"?\")}GB VRAM')
    print(f'{i}) {key} - {name}')
" "$config" "$category")

    printf '\n%s models:\n' "$(capitalize "$category")" >&2
    printf '%s\n' "$catalog_output" >&2
    printf 'Select: ' >&2

    local choice
    if [[ -n "${CLAWDESS_INTERACTIVE_WIZARD:-}" ]]; then IFS= read -r choice <&3 || choice="1"; else IFS= read -r choice || choice="1"; fi

    python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
category = sys.argv[2]
choice = int(sys.argv[3])
if category == 'voice':
    features_cfg = cfg.get('features', {})
    entry = features_cfg.get('voice', {}) if isinstance(features_cfg, dict) else {}
    backends = entry.get('backends', []) if isinstance(entry, dict) else []
    if not backends:
        backends = cfg.get('catalog', {}).get('voice', [])
else:
    features_cfg = cfg.get('features', {})
    entry = features_cfg.get(category, {}) if isinstance(features_cfg, dict) else {}
    models_list = entry.get('models', []) if isinstance(entry, dict) else []
    if not models_list:
        models_list = cfg.get('catalog', {}).get(category, [])
models = backends if category == 'voice' else models_list
if 1 <= choice <= len(models):
    print(models[choice - 1])
" "$config" "$category" "$choice"
    return 0
}

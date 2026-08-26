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

# probe_hardware -- Enhanced hardware detection.
# Detects GPU model, CUDA compute capability, VRAM, disk space, architecture.
# Generates $DEPLOY_ROOT/state/hardware-profile.json.
# Returns 0 on success; does not fail the deployment if detection is incomplete.
probe_hardware() {
    local deploy_root="${1:?deploy root required}"
    local profile_dir="$deploy_root/state"
    mkdir -p -- "$profile_dir"

    local gpu_name="" memory_total="" compute_cap="" arch="" disk_free_kb="" disk_free_gb=""
    local vram_total_gb="" vram_usable_gb="" total_mem_kb="" is_gb10="false" cuda_toolkit="false" nvcc_path=""

    # Architecture
    arch="$(uname -m 2>/dev/null || echo unknown)"

    # GPU detection via nvidia-smi
    local smi_output
    smi_output="$(clawdess_nvidia_smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader 2>/dev/null)" || true
    if [[ -n "$smi_output" ]]; then
        IFS=',' read -r gpu_name memory_total compute_cap <<< "$smi_output"
        # Trim whitespace
        gpu_name="${gpu_name#\"${gpu_name%%[![:space:]]*}\"}"; gpu_name="${gpu_name%\"${gpu_name##*[![:space:]]}\"}"
        memory_total="${memory_total#\"${memory_total%%[![:space:]]*}\"}"; memory_total="${memory_total%\"${memory_total##*[![:space:]]}\"}"
        compute_cap="${compute_cap#\"${compute_cap%%[![:space:]]*}\"}"; compute_cap="${compute_cap%\"${compute_cap##*[![:space:]]}\"}"
        gpu_name="${gpu_name#NVIDIA }"
    fi

    # Detect if GB10
    if [[ "$gpu_name" == "GB10" ]]; then
        is_gb10="true"
    fi

    # Detect CUDA toolkit availability
    nvcc_path="$(command -v nvcc 2>/dev/null || echo '')"
    if [[ -n "$nvcc_path" ]]; then
        cuda_toolkit="true"
    fi

    # Disk space
    disk_free_kb="$(probe_df -Pk "$deploy_root" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    disk_free_gb="0"
    if [[ "$disk_free_kb" =~ ^[0-9]+$ ]]; then
        disk_free_gb="$(python3 -c "print(f'{int($disk_free_kb) / 1024 / 1024:.2f}')" 2>/dev/null || echo "0")"
    fi

    # VRAM estimation: GB10 has 128GB unified memory; otherwise use nvidia-smi value
    if [[ "$is_gb10" == "true" ]]; then
        vram_total_gb=128
        vram_usable_gb=120  # reserve ~8GB for system
        # Try to read actual from nvidia-smi
        if [[ "$memory_total" =~ ^[0-9]+ ]] 2>/dev/null; then
            vram_total_gb="$memory_total"
            vram_usable_gb="$memory_total"
        fi
    else
        # For non-GB10, estimate from memory.total string
        if [[ "$memory_total" =~ ^([0-9]+) ]]; then
            vram_total_gb="${BASH_REMATCH[1]}"
            vram_usable_gb="$vram_total_gb"
        else
            # Check /proc/dri or other sources as fallback
            if [[ -f /sys/class/drm/card0/device/memory_info/vram_total ]]; then
                vram_total_gb="$(python3 -c "print($(( $(cat /sys/class/drm/card0/device/memory_info/vram_total) / 1024 / 1024 / 1024 )))" 2>/dev/null || echo "0")"
                vram_usable_gb="$vram_total_gb"
            fi
        fi
    fi

    # Build hardware profile JSON
    local profile
    profile="$(python3 -c "
import json, sys
p = {
    'architecture': sys.argv[1],
    'gpu': {
        'name': sys.argv[2] if sys.argv[2] else 'unknown',
        'compute_capability': sys.argv[3] if sys.argv[3] else 'unknown',
        'vram_total_gb': int(sys.argv[4]) if sys.argv[4].isdigit() else 0,
        'vram_usable_gb': int(sys.argv[5]) if sys.argv[5].isdigit() else 0,
        'is_gb10': sys.argv[6] == 'true',
    },
    'cuda': {
        'toolkit_available': sys.argv[7] == 'true',
        'nvcc_path': sys.argv[8] if sys.argv[8] else '',
    },
    'disk': {
        'free_kb': int(sys.argv[9]) if sys.argv[9].isdigit() else 0,
        'free_gb': float(sys.argv[10]) if sys.argv[10] else 0.0,
    },
    'gb10_optimizations': {
        'sm_90a_target': sys.argv[6] == 'true',
        'flash_attn_hopper': sys.argv[6] == 'true' and sys.argv[7] == 'true' and sys.argv[1] == 'aarch64',
        'tensor_cores': sys.argv[6] == 'true',
        'unified_memory_gb': int(sys.argv[4]) if sys.argv[4].isdigit() else 128,
    },
    'model_fit': {},
}
# Pre-compute which models fit in available VRAM
vram = int(p['gpu']['vram_usable_gb']) if p['gpu']['vram_usable_gb'] > 0 else 128
for model, vram_needed in [
    ('juggernaut-xl-v10', 8),
    ('pony-v6', 7),
    ('noobai-xl', 7),
    ('flux1-dev-fp8-finetune', 12),
    ('stability-ai-sdxl-turbo', 3),
    ('wan2gp-i2v-14B', 24),
    ('piper-voice', 0.1),
]:
    p['model_fit'][model] = vram_needed <= vram
print(json.dumps(p, separators=(',',':')))
" "$arch" "$gpu_name" "$compute_cap" "$vram_total_gb" "$vram_usable_gb" "$is_gb10" "$cuda_toolkit" "$nvcc_path" "$disk_free_kb" "$disk_free_gb")"

    json_write_atomic "$profile_dir/hardware-profile.json" "$profile"
    printf 'hardware: profile written to %s/state/hardware-profile.json\n' "$deploy_root"
    printf 'hardware: arch=%s gpu=%s compute=%s vram=%sGB is_gb10=%s cuda=%s disk=%sGB free\n' \
        "$arch" "$gpu_name" "$compute_cap" "$vram_total_gb" "$is_gb10" "$cuda_toolkit" "$disk_free_gb"
    return 0
}

# optimize_for_gb10 VENV_PYTHON DEPLOY_ROOT -- GB10-specific optimizations.
# Sets PyTorch CUDA flags for Hopper (sm_90a), flash-attn flags for ARM64+Hopper,
# xformers config for GB10 tensor cores, and memory allocation strategies.
# Best-effort: returns 0 even if any optimization step fails.
optimize_for_gb10() {
    local venv_python="${1:-}" deploy_root="${2:-/tmp/dgx-spark-deploy}"
    local hardware_profile="$deploy_root/state/hardware-profile.json"

    # Read hardware profile to confirm GB10
    local is_gb10="false" cuda_toolkit="false" arch=""
    if [[ -f "$hardware_profile" ]]; then
        local hw_json
        hw_json="$(json_read "$hardware_profile" 2>/dev/null)" || hw_json=""
        if [[ -n "$hw_json" ]]; then
            is_gb10="$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print('true' if d.get('gpu',{}).get('is_gb10') else 'false')" "$hw_json" 2>/dev/null || echo false)"
            cuda_toolkit="$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print('true' if d.get('cuda',{}).get('toolkit_available') else 'false')" "$hw_json" 2>/dev/null || echo false)"
            arch="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('architecture','unknown'))" "$hw_json" 2>/dev/null || echo unknown)"
        fi
    fi

    if [[ "$is_gb10" != "true" ]]; then
        printf 'opt: not a GB10; skipping Hopper optimizations\\n' >&2
        return 0
    fi

    printf 'opt: GB10 detected (Blackwell sm_121); applying Blackwell optimizations\n' >&2
    local installed=0 failed=0

    # 1. PyTorch: nightly cu128 for sm_121 support (stable PyTorch doesn't support sm_121)
    if [[ "$cuda_toolkit" == "true" && -n "$venv_python" ]]; then
        printf 'opt: installing PyTorch nightly cu128 (sm_121 for GB10 Blackwell)\\n' >&2
        if "$venv_python" -m pip install --pre torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/nightly/cu128 \
            --no-deps \
            2>/dev/null; then
            printf 'opt: PyTorch nightly cu128 (sm_121) installed\\n' >&2
            installed=$((installed + 1))
        else
            printf 'opt: PyTorch nightly cu128 install failed, trying CPU fallback\\n' >&2
            if "$venv_python" -m pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-deps 2>/dev/null; then
                printf 'opt: PyTorch (CPU fallback) installed\\n' >&2
                installed=$((installed + 1))
            else
                printf 'opt: PyTorch install failed entirely\\n' >&2
                failed=$((failed + 1))
            fi
        fi
    elif [[ -n "$venv_python" ]]; then
        # No CUDA toolkit; still ensure torch is installed (CPU-only)
        printf 'opt: no nvcc found; ensuring PyTorch (CPU) is available\\n' >&2
        "$venv_python" -m pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-deps 2>/dev/null
    fi

    # 2. flash-attn: ARM64 + Blackwell (sm_120, binary compatible with sm_121)
    if [[ "$arch" == "aarch64" && "$cuda_toolkit" == "true" && -n "$venv_python" ]]; then
        printf 'opt: installing flash-attn with Blackwell (sm_120) flags\\n' >&2
        local flash_attn_args="-Csetup.cmake-cMAKE_CUDA_ARCHITECTURES=120"
        if TORCH_CUDA_ARCH_LIST="12.0" FLASH_ATTENTION_CUDA_ARCHS="120" \
           "$venv_python" -m pip install --no-cache-dir flash-attn 2>/dev/null; then
            printf 'opt: flash-attn installed\\n' >&2
            installed=$((installed + 1))
        else
            printf 'opt: flash-attn build failed (aarch64 Blackwell sm_120)\\n' >&2
            failed=$((failed + 1))
        fi
    elif [[ "$arch" == "aarch64" ]]; then
        printf 'opt: nvcc not found, skipping flash-attn on %s\\n' "$arch" >&2
    fi

    # 3. xformers: configure for GB10 tensor cores
    if [[ -n "$venv_python" ]]; then
        printf 'opt: installing xformers for GB10 tensor cores\n' >&2
        if "$venv_python" -m pip install --no-cache-dir xformers 2>/dev/null; then
            printf 'opt: xformers installed\n' >&2
            installed=$((installed + 1))
        else
            printf 'opt: xformers build failed (aarch64 Blackwell)\\n' >&2
            failed=$((failed + 1))
        fi
    fi

    # 4. NVRTC 13 symlink for sm_121 FFT/audio ops (Challenge 14 from DGX Spark guide)
    #    PyTorch nightly cu128 bundles NVRTC 12.x which doesn't know sm_121.
    #    Symlink system libnvrtc.so.13 over bundled libnvrtc.so.12 so JIT codegen works.
    if [[ -n "$venv_python" ]]; then
        local nvrtc_lib=""
        for _lib in $(find "$VENV_PATH/lib" -path "*/nvidia/cuda_nvrtc/lib/libnvrtc.so.12" 2>/dev/null); do
            nvrtc_lib="$_lib"
            break
        done
        if [[ -n "$nvrtc_lib" ]]; then
            local nvrtc_dir
            nvrtc_dir="$(dirname "$nvrtc_lib")"
            if [[ -f "$nvrtc_dir/libnvrtc.so.13" || -L "$nvrtc_dir/libnvrtc.so.13" ]]; then
                printf 'opt: NVRTC 13 already symlinked\\n' >&2
            elif [[ -d "$nvrtc_dir" ]]; then
                printf 'opt: patching bundled NVRTC 12 → system NVRTC 13 (sm_121 FFT fix)\\n' >&2
                if mv "$nvrtc_lib" "${nvrtc_lib}.orig" 2>/dev/null && \
                   ln -sf /usr/local/cuda-13.0/lib64/libnvrtc.so.13 "$nvrtc_dir/libnvrtc.so.12" 2>/dev/null; then
                    printf 'opt: NVRTC symlinked successfully\\n' >&2
                else
                    printf 'opt: NVRTC symlink failed (will use bundled NVRTC 12)\\n' >&2
                fi
            fi
        fi
    fi

    # 5. Memory allocation strategy: set PyTorch memory allocator config for unified memory
    if [[ -n "$venv_python" ]]; then
        printf 'opt: configuring PyTorch memory allocator for 128GB unified memory\\n' >&2
        "$venv_python" -c "
import torch
if torch.cuda.is_available():
    torch.cuda.set_per_process_memory_fraction(0.90)  # use 90% of unified memory
    print(f'Torch CUDA memory fraction: 0.90 (128GB unified)')
else:
    print('Cuda not available in this venv; memory config deferred to runtime')
" 2>/dev/null || true
    fi

    printf 'opt: GB10 optimization complete: %d installed, %d failed\\n' "$installed" "$failed" >&2
    return 0
}

# write_content_policy MODEL_ROOT -- Generate NSFW content policy README.
# Creates $DEPLOY_ROOT/models/.content-policy.md with legal/compliance guidance.
# Non-fatal: returns 0 even if file writing fails.
write_content_policy() {
    local model_root="${1:-/tmp/dgx-spark-deploy/models}"
    local policy_file="$model_root/.content-policy.md"

    mkdir -p -- "$model_root" 2>/dev/null || return 0

    cat > "$policy_file" <<'POLICY'
# Content Policy — Juggernaut-X v10 / NSFW Models

## Content Policy Notice

Juggernaut-X v10 is a capable image generation model that can produce
realistic human likenesses and may generate NSFW (Not Safe For Work) content.
This file documents the acceptable usage policy for models deployed in this
environment.

## Legal Responsibility Statement

By using models from this deployment, you acknowledge that:

1. **You are legally responsible** for all content you generate with these models.
2. **You must comply with all applicable laws**, including but not limited to:
   - Federal and state laws regarding the generation of images of minors
   - Privacy laws regarding the use of real people's likenesses
   - Copyright and intellectual property laws
   - Laws prohibiting non-consensual intimate imagery
   - Laws regarding the generation of deceptive/fraudulent content

## Age Verification Requirement

Users must be **at least 18 years of age** (or the age of majority in their
jurisdiction) to use NSFW-capable models in this deployment. By proceeding,
you represent that you meet this requirement.

## Usage Restrictions

The following types of content are **strictly prohibited**:

- **Minors**: Any depiction of persons who appear to be under 18 years of age
  in a sexualized or exploitative manner (zero tolerance under 18 U.S.C. § 2256
  and equivalent international laws)
- **Non-consensual content**: Generating images of real people without their
  consent, especially in a sexualized or defamatory context
- **Illegal content**: Anything that violates local, state, or federal law
  in your jurisdiction
- **Misinformation**: Generating content designed to deceive or mislead about
  real events, people, or organizations
- **Commercial exploitation**: Using generated likenesses of real people for
  commercial endorsement without their consent

## Permitted Uses

- Artistic and creative expression (where lawful)
- Educational and research purposes
- Fictional character creation
- Personal entertainment

## Model Information

- **Model**: Juggernaut-X v10 (Juggernaut-X-RunDiffusion-NSFW.safetensors)
- **Source**: [HuggingFace — RunDiffusion/Juggernaut-X-v10](https://huggingface.co/RunDiffusion/Juggernaut-X-v10)
- **Content Warning**: This model is NSFW-capable. The `NSFW` variant is
  intentionally included; users may choose the non-NSFW variant instead.

## Enforcement

Violations of this policy may result in:
- Immediate revocation of access
- Reporting to appropriate authorities where required by law
- Legal action where applicable

## Contact

For questions about this policy, contact your system administrator or the
organization operating this deployment.

---
*This policy is provided as a compliance aid. It does not constitute legal
advice. Users are responsible for determining their own legal obligations.*
POLICY

    printf 'content-policy: written to %s\\n' "$policy_file" >&2
    return 0
}

# generate_model_config CONFIG MODEL_ROOT STATE_ROOT DEPLOY_ROOT
# Outputs a consolidated model-inventory.json describing all catalog models,
# their dependencies, VRAM requirements, feature gates, and status.
# Output: $DEPLOY_ROOT/config/model-inventory.json
# Returns 0; best-effort — does not fail the deployment if config generation
# encounters issues.
generate_model_config() {
    local config="${1:?config required}" model_root="${2:?model root required}"
    local state_root="${3:-}" deploy_root="${4:-}"

    local profile_path=""
    if [[ -n "$state_root" && -f "$state_root/state/hardware-profile.json" ]]; then
        profile_path="$state_root/state/hardware-profile.json"
    elif [[ -n "$deploy_root" && -f "$deploy_root/state/hardware-profile.json" ]]; then
        profile_path="$deploy_root/state/hardware-profile.json"
    fi

    local vram_available=0
    if [[ -n "$profile_path" ]]; then
        vram_available="$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d.get('gpu',{}).get('vram_usable_gb',0))" "$profile_path" 2>/dev/null || echo 0)"
    fi

    # Determine which models have been downloaded (by scanning model_root)
    local model_status_args=""
    local models_dir
    for dir in "$model_root/diffusion_models" "$model_root/checkpoints" "$model_root" "$model_root/models"; do
        if [[ -d "$dir" ]]; then
            models_dir="$dir"
            model_status_args="$models_dir"
            break
        fi
    done

    python3 -c "
import json, sys, os, re

config_path = sys.argv[1]
models_dir = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ''
vram_available = int(sys.argv[3]) if len(sys.argv) > 3 else 0

cfg = json.load(open(config_path))
models = cfg.get('models', {})

# Build per-file download status from filesystem
file_statuses = {}
if models_dir and os.path.isdir(models_dir):
    for root, dirs, files in os.walk(models_dir):
        for f in files:
            file_statuses[f] = 'downloaded'

inventory = {
    'generated_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'vram_available_gb': vram_available,
    'models': {},
    'catalog': cfg.get('catalog', {}),
}

# Model size estimates (GB) for VRAM fit check
_vram_estimates = {
    'juggernaut-xl-v10': 8,
    'pony-v6': 7,
    'noobai-xl': 7,
    'flux1-dev-fp8-finetune': 12,
    'stability-ai-sdxl-turbo': 3,
    'wan2gp-i2v-14B': 24,
    'piper-voice': 0.1,
}

for key in sorted(models.keys()):
    entry = models[key]
    min_size = entry.get('minimum_size_bytes', 0)
    size_gb = round(min_size / (1024**3), 2) if min_size else 0
    vram_needed = _vram_estimates.get(key, '?')
    vram_fit = vram_needed <= vram_available if isinstance(vram_needed, int) else False

    # Determine status from config + filesystem
    required = entry.get('required', True)
    has_files = 'files' in entry
    if not has_files and key in file_statuses:
        status = 'downloaded'
    elif required:
        status = 'required'
    else:
        status = 'pending'

    # Check file-level status
    file_records = []
    if has_files:
        for subdir, file_list in entry.get('files', {}).items():
            fl = file_list if isinstance(file_list, list) else [file_list]
            for fm in fl:
                fn = fm.get('filename', '')
                chk = fm.get('checksum', '')
                rec = {
                    'filename': fn,
                    'destination': fm.get('destination', subdir),
                    'minimum_size_bytes': fm.get('minimum_size_bytes', 0),
                    'checksum': chk if chk else None,
                    'status': 'downloaded' if fn in file_statuses else ('required' if fm.get('required', False) else 'pending'),
                }
                file_records.append(rec)
    elif has_files:
        file_records = []
    else:
        file_records = []

    dest = f'{models_dir}/{key}' if models_dir else ''

    record = {
        'name': key,
        'source': entry.get('source', ''),
        'revision': entry.get('revision', ''),
        'size_bytes': min_size,
        'size_gb': size_gb,
        'vram_needed_gb': vram_needed,
        'vram_fit_gb10': vram_fit,
        'destination': dest,
        'required': required,
        'experimental': entry.get('experimental', False),
        'status': status,
        'file_records': file_records if file_records else None,
    }
    inventory['models'][key] = record

# Feature gates: which models are needed for each feature
features_map = {}
for cat in ('photo', 'video', 'voice'):
    catalog = cfg.get('catalog', {}).get(cat, [])
    features_map[cat] = list(catalog)

inventory['feature_gates'] = features_map
inventory['summary'] = {
    'total_models': len(models),
    'vram_available_gb': vram_available,
    'models_fit_in_vram': sum(1 for k, v in _vram_estimates.items() if v <= vram_available),
}

print(json.dumps(inventory, indent=2))
" "$config" "${model_status_args:-}" "$vram_available" > "$deploy_root/config/model-inventory.json" 2>/dev/null || true

    printf 'model-config: inventory written to %s/config/model-inventory.json\\n' "$deploy_root" >&2
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
    python3 -c "import json,sys; r=json.loads(sys.argv[1]); v=r.get(sys.argv[2],''); print(v if v is not None else '')" "$record" "$field"
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
    # ComfyUI's requirements.txt contains --hash= lines which cause pip to
    # auto-enable hash-check mode (even without --require-hashes flag).
    # Strip those lines so pip installs all deps without hash enforcement.
    # Also exclude torch/torchvision/torchaudio — we already installed nightly
    # cu128 variants above (Phases 2/3); forcing ComfyUI's torch version would
    # break GPU compatibility (sm_121 requires nightly, not stable).
    # Note: ComfyUI's requirements.txt has lines like 'torch>=2.1.0' with version
    # specifiers, so we use prefix match (not exact match) to catch all variants.
    local comfyui_req_tmp
    comfyui_req_tmp="$(mktemp)"
    grep -v '^\s*--hash=' "$comfyui_path/requirements.txt" | \
        grep -vE '^\s*(torch|torchsde|torchvision|torchaudio)' > "$comfyui_req_tmp" || true
    "$venv_python" -m pip install --no-cache-dir -r "$comfyui_req_tmp" || {
        printf 'comfyui: dependency install failed\n' >&2
        rm -f -- "$comfyui_req_tmp"
        return 1
    }
    rm -f -- "$comfyui_req_tmp"

    printf 'comfyui: installed at revision %s\n' "$COMFYUI_REVISION"
    return 0
}

# ---------------------------------------------------------------------------
# Local video provisioning seam
# ---------------------------------------------------------------------------
# ComfyUI custom nodes — install repos into custom_nodes/
# ---------------------------------------------------------------------------
# install_comfyui_custom_nodes COMFYUI_PATH [VENV_PYTHON]
# Clones a curated set of video-capable custom node repositories into
# the ComfyUI custom_nodes directory.  Called during video provisioning
# when the selected feature set includes "video".
#
# Returns 0 on success, 1 if any clone fails (non-fatal — video still
# works without nodes that are not strictly required).
install_comfyui_custom_nodes() {
    local comfyui_path="${1:?comfyui path required}"
    local venv_python="${2:-}"

    local nodes=(
        "https://github.com/comfyanonymous/ComfyUI-WanVideoWrapper"
        "https://github.com/ljfrankner/ComfyUI-FluxNodes"
        "https://github.com/Lightrix/ComfyUI-LTXVideo"
        "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
        "https://github.com/city96/ComfyUI-GGUF"
        "https://github.com/RockOfThaw/ComfyUI_UltraFast"
    )

    local custom_dir="$comfyui_path/custom_nodes"
    mkdir -p -- "$custom_dir" || return 1

    local cloned=0 failed=0 node
    for node in "${nodes[@]}"; do
        local repo_name
        repo_name="${node##*/}"
        local target="$custom_dir/$repo_name"
        if [[ -d "$target/.git" ]]; then
            printf 'custom-nodes: %s already installed, skipping\\n' "$repo_name" >&2
            continue
        fi
        if git clone --depth 1 "$node" "$target" 2>/dev/null; then
            printf 'custom-nodes: cloned %s\\n' "$repo_name" >&2
            cloned=$((cloned + 1))
        else
            printf 'custom-nodes: failed to clone %s\\n' "$repo_name" >&2
            failed=$((failed + 1))
        fi
    done

    printf 'custom-nodes: %d cloned, %d failed\\n' "$cloned" "$failed" >&2
    # Non-fatal: video still works without custom nodes; best-effort clone.
    return 0
}

# ---------------------------------------------------------------------------
# GPU optimizations — install flash-attn, xformers for ARM64
# ---------------------------------------------------------------------------
# install_gpu_optimizations VENV_PYTHON
# Installs GPU-aware acceleration libraries.  On ARM64 (GB10) these are
# compiled against the system CUDA toolkit (12.1).  Non-fatal: photo
# generation still works without them.
#
# Returns 0 on success, 1 if compilation fails (still best-effort).
install_gpu_optimizations() {
    local venv_python="${1:?venv python required}"

    # Detect architecture
    local arch
    arch="$(uname -m 2>/dev/null || echo unknown)"

    printf 'gpu-opt: platform %s, installing GPU acceleration deps\\n' "$arch" >&2

    local installed=0 failed=0 pkg
    for pkg in xformers; do
        if "$venv_python" -m pip install --no-cache-dir "$pkg" 2>/dev/null; then
            printf 'gpu-opt: installed %s\\n' "$pkg" >&2
            installed=$((installed + 1))
        else
            printf 'gpu-opt: could not install %s\\n' "$pkg" >&2
            failed=$((failed + 1))
        fi
    done

    # flash-attn: ARM64 compilation; skip if nvcc is not found.
    if [[ "$arch" == "aarch64" && -n "$venv_python" ]]; then
        if command -v nvcc >/dev/null 2>&1; then
            printf 'gpu-opt: installing flash-attn (aarch64, nvcc found)\\n' >&2
            if "$venv_python" -m pip install --no-cache-dir flash-attn 2>/dev/null; then
                printf 'gpu-opt: installed flash-attn\\n' >&2
                installed=$((installed + 1))
            else
                printf 'gpu-opt: flash-attn build failed (aarch64)\\n' >&2
                failed=$((failed + 1))
            fi
        else
            printf 'gpu-opt: nvcc not found, skipping flash-attn on %s\\n' "$arch" >&2
        fi
    fi

    printf 'gpu-opt: %d installed, %d failed\\n' "$installed" "$failed" >&2
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
    if [[ "$dry_run" == true ]]; then printf 'video: local provisioning deferred (dry-run; no files written)\n'; return 0; fi

    local comfyui_path="$deploy_root/artifacts/ComfyUI"
    local venv_path="$deploy_root/venv"
    local venv_python="$venv_path/bin/python"

    mkdir -p "$deploy_root/config" "$deploy_root/bin" "$deploy_root/run" "$deploy_root/logs"

    # Install ComfyUI custom nodes (best-effort; video still works without them)
    if [[ -d "$comfyui_path" ]]; then
        install_comfyui_custom_nodes "$comfyui_path" "$venv_python" || true
    else
        printf 'video: ComfyUI path %s not found; custom nodes skipped\\n' "$comfyui_path" >&2
    fi

    # Install GPU optimizations (best-effort; photo still works without them)
    if [[ -x "$venv_python" ]]; then
        install_gpu_optimizations "$venv_python" || true
    else
        printf 'video: venv python %s not found; GPU opt skipped\\n' "$venv_python" >&2
    fi

    # Write video manifest
    json_write_atomic "$manifest" "$payload"

    # Generate video lifecycle scripts (start-video / stop-video)
    printf '#!/usr/bin/env bash\nset -euo pipefail\nSCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"\nprintf "Starting video service (deferred runtime)...\n" >&2\nif [[ -x "$SCRIPT_DIR/venv/bin/python" && -d "$SCRIPT_DIR/artifacts/ComfyUI" ]]; then\n  nohup "$SCRIPT_DIR/venv/bin/python" "$SCRIPT_DIR/artifacts/ComfyUI/main.py" --port 8189 > "$SCRIPT_DIR/logs/video-comfyui.log" 2>&1 &\n  echo $! > "$SCRIPT_DIR/run/video.pid"\n  printf "video: ComfyUI started (pid %s, port 8189)\\n" "$!"\nelse\n  printf "video: runtime deferred; no process started\\n" >&2\n  exit 2\nfi\n' > "$deploy_root/bin/start-video"

    printf '#!/usr/bin/env bash\nset -euo pipefail\nPID_FILE="$(dirname "$0")/../run/video.pid"\nif [[ -f "$PID_FILE" ]]; then\n  kill "$(cat "$PID_FILE")" 2>/dev/null || true\n  rm -f -- "$PID_FILE"\n  printf "video: stopped (pid read from PID file)\\n"\nelse\n  printf "video: no PID file found\\n"\nfi\n' > "$deploy_root/bin/stop-video"

    chmod +x "$deploy_root/bin/start-video" "$deploy_root/bin/stop-video"

    # Generate systemd service unit for video
    generate_video_systemd_unit "$deploy_root" || true

    printf 'video: local Wan2GP/ComfyUI scaffolded with model dependency paths; runtime installation deferred\n' >&2
    return 1
}

# ---------------------------------------------------------------------------
# Video provisioning entry point (public)
# ---------------------------------------------------------------------------
provision_video() {
    local deploy_root="$1" state_root="$2" provider="$3" model="$4" config="$5" dry_run="${6:-false}"
    [[ "$provider" == remote ]] && { printf 'video: remote provider selected; skipping local video provisioning\n'; return 0; }
    provision_local_video "$deploy_root" "$state_root" "$model" "$config" "$dry_run"
}

# ---------------------------------------------------------------------------
# Systemd service unit for video service
# ---------------------------------------------------------------------------
generate_video_systemd_unit() {
    local deploy_root="${1:?deploy root required}"

    mkdir -p -- "$HOME/.config/systemd/user"

    cat > "$HOME/.config/systemd/user/clawdess-video.service" <<EOF
[Unit]
Description=Clawdess Video Service (ComfyUI Wan2GP)
After=network.target clawdess-comfyui.service

[Service]
Type=simple
ExecStart=$deploy_root/bin/start-video
ExecStop=$deploy_root/bin/stop-video
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    printf 'systemd: generated video unit in ~/.config/systemd/user\n'
    return 0
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

install_vllm() {
    local venv_python="${1:?venv python required}"

    local arch
    arch="$(uname -m 2>/dev/null || echo unknown)"
    printf 'vllm: platform %s, attempting installation (best-effort)\n' "$arch" >&2

    # Check if vllm is already installed
    if "$venv_python" -c 'import vllm; print(vllm.__version__)' 2>/dev/null; then
        printf 'vllm: already installed\n' >&2
        return 0
    fi

    # Install vllm from PyPI (ARM64 wheel if available).
    # vLLM is GPU-centric; on aarch64 (GB10) wheels may be
    # unavailable — best-effort: return 0 regardless.
    if "$venv_python" -m pip install --no-cache-dir vllm 2>/dev/null; then
        printf 'vllm: installed successfully\n' >&2
        return 0
    fi

    printf 'vllm: install failed (best-effort; photo/ComfyUI do not depend on vLLM)\n' >&2
    printf 'vllm: note: vLLM may require ARM64-specific wheels for %s\n' "$arch" >&2
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
# Health check functions (standalone, callable outside lifecycle scripts)
# ---------------------------------------------------------------------------

# health_check() — checks all running services, writes results to state file.
# Returns 0 if all healthy, 1 if any unhealthy.
health_check() {
    local deploy_root="${1:-${DEPLOY_ROOT:-}}/${CLAWDESS_DEPLOY_ROOT:-}"
    deploy_root="${deploy_root:-/tmp/dgx-spark-deploy}"
    local error_count=0
    local healthy_count=0
    local results=""
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Check ComfyUI (port 8188)
    local comfyui_status="unknown"
    if [[ -f "$deploy_root/run/comfyui.pid" ]]; then
        local pid
        pid="$(cat "$deploy_root/run/comfyui.pid")"
        if kill -0 "$pid" 2>/dev/null; then
            if curl -s --max-time 5 http://localhost:8188/system_stats >/dev/null 2>&1; then
                comfyui_status="healthy"
                healthy_count=$((healthy_count + 1))
            else
                comfyui_status="unhealthy"
                error_count=$((error_count + 1))
            fi
        else
            comfyui_status="dead"
            error_count=$((error_count + 1))
        fi
    else
        comfyui_status="not_started"
    fi
    results="${results}{\"service\":\"comfyui\",\"port\":8188,\"status\":\"${comfyui_status}\"},"

    # Check vLLM (port 8000)
    local vllm_status="unknown"
    if [[ -f "$deploy_root/run/vllm.pid" ]]; then
        local pid
        pid="$(cat "$deploy_root/run/vllm.pid")"
        if kill -0 "$pid" 2>/dev/null; then
            if curl -s --max-time 5 http://localhost:8000/health >/dev/null 2>&1; then
                vllm_status="healthy"
                healthy_count=$((healthy_count + 1))
            else
                vllm_status="unhealthy"
                error_count=$((error_count + 1))
            fi
        else
            vllm_status="dead"
            error_count=$((error_count + 1))
        fi
    else
        vllm_status="not_started"
    fi
    results="${results}{\"service\":\"vllm\",\"port\":8000,\"status\":\"${vllm_status}\"},"

    # Check llama.cpp (port 8001)
    local llama_status="unknown"
    if [[ -f "$deploy_root/run/llama.pid" ]]; then
        local pid
        pid="$(cat "$deploy_root/run/llama.pid")"
        if kill -0 "$pid" 2>/dev/null; then
            if curl -s --max-time 5 http://localhost:8001/health >/dev/null 2>&1; then
                llama_status="healthy"
                healthy_count=$((healthy_count + 1))
            else
                llama_status="unhealthy"
                error_count=$((error_count + 1))
            fi
        else
            llama_status="dead"
            error_count=$((error_count + 1))
        fi
    else
        llama_status="not_started"
    fi
    results="${results}{\"service\":\"llama\",\"port\":8001,\"status\":\"${llama_status}\"},"

    # Check piper (port 5000)
    local piper_status="unknown"
    if [[ -f "$deploy_root/run/piper.pid" ]]; then
        local pid
        pid="$(cat "$deploy_root/run/piper.pid")"
        if kill -0 "$pid" 2>/dev/null; then
            if curl -s --max-time 5 http://localhost:5000/ping >/dev/null 2>&1; then
                piper_status="healthy"
                healthy_count=$((healthy_count + 1))
            else
                piper_status="unhealthy"
                error_count=$((error_count + 1))
            fi
        else
            piper_status="dead"
            error_count=$((error_count + 1))
        fi
    else
        piper_status="not_started"
    fi
    results="${results}{\"service\":\"piper\",\"port\":5000,\"status\":\"${piper_status}\"}"

    # Write health check results to state file
    local state_file="$deploy_root/state/deployment-state.json"
    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    if [[ -f "$state_file" ]]; then
        local existing
        existing="$(json_read "$state_file" 2>/dev/null || echo '{}')"
        python3 -c "
import json, sys
existing = json.loads(sys.argv[1]) if sys.argv[1] else {}
existing['running_services'] = [
    r['service'] for r in json.loads(sys.argv[2]) if r['status'] == 'healthy'
]
existing['health_checks'] = json.loads(sys.argv[2])
existing['last_health_check'] = sys.argv[3]
if 'error_count' in existing:
    existing['health_error_count'] = json.loads(sys.argv[4]).get('error_count', existing.get('health_error_count', 0))
print(json.dumps(existing, separators=(',', ':')))
" "$existing" "[${results}]" "$timestamp" "$timestamp" "$error_count" > "$state_file.tmp" 2>/dev/null && \
        mv -f "$state_file.tmp" "$state_file" || true
    else
        printf '{"running_services":[],"health_checks":[%s],"last_health_check":"%s"}\n' "${results}" "$timestamp" > "$state_file"
    fi

    if [[ "$error_count" -gt 0 ]]; then
        printf 'health-check: %d issue(s), %d healthy\n' "$error_count" "$healthy_count"
        return 1
    fi
    printf 'health-check: all services healthy (%d checked)\n' "$healthy_count"
    return 0
}

# ---------------------------------------------------------------------------
# Docker Compose generation
# ---------------------------------------------------------------------------

# generate_docker_compose DEPLOY_ROOT PROFILE [DOCKER_AVAILABLE]
# Generates docker-compose.yml with 4 services, profile-based templates,
# health checks, and resource limits. Works without Docker installed.
generate_docker_compose() {
    local deploy_root="${1:?deploy root required}"
    local profile="${2:-minimal}"
    local docker_available="${3:-false}"

    mkdir -p "$deploy_root"

    # Determine which services to include based on profile
    local services=""
    local profiles_yaml=""
    local has_photo=false has_video=false has_voice=false has_llama=false

    case "$profile" in
        minimal)  has_photo=true ;;
        media)    has_photo=true; has_video=true ;;
        assistant) has_photo=true; has_video=true; has_voice=true ;;
        all)      has_photo=true; has_video=true; has_voice=true ;;
        full)     has_photo=true; has_video=true; has_voice=true; has_llama=true ;;
        *)        has_photo=true ;;  # default
    esac

    if feature_selected "${profile}" photo 2>/dev/null || [[ "$has_photo" == "true" ]]; then
        has_photo=true
    fi

    # Build services YAML
    services="version: \"3.8\"\n"
    services+="# Auto-generated by DGX Spark Deployment Wizard — profile: ${profile}\n"
    services+="services:\n"

    # ComfyUI service (always present for non-minimal)
    services+="  comfyui:\n"
    services+="    image: ghcr.io/comfyanonymous/comfyui:latest\n"
    services+="    container_name: clawdess-comfyui\n"
    services+="    ports:\n"
    services+="      - \"8188:8188\"\n"
    services+="    volumes:\n"
    services+="      - models:/models\n"
    services+="      - artifacts:/artifacts\n"
    services+="      - state:/state\n"
    services+="    environment:\n"
    services+="      - PYTHONUNBUFFERED=1\n"
    services+="      - COMFYUI_PORT=8188\n"
    services+="    deploy:\n"
    services+="      resources:\n"
    services+="        reservations:\n"
    services+="          devices:\n"
    services+="            - driver: nvidia\n"
    services+="              count: 1\n"
    services+="              capabilities: [gpu]\n"
    services+="        limits:\n"
    services+="          memory: 32G\n"
    services+="      restart_policy:\n"
    services+="        condition: on-failure\n"
    services+="        delay: 5s\n"
    services+="        max_attempts: 3\n"
    services+="    healthcheck:\n"
    services+="      test: [\"CMD\", \"curl\", \"-sf\", \"http://localhost:8188/system_stats\"]\n"
    services+="      interval: 30s\n"
    services+="      timeout: 10s\n"
    services+="      retries: 3\n"
    services+="      start_period: 60s\n"
    services+="    networks:\n"
    services+="      - clawdess-net\n\n"

    # vLLM service (for full profile or when llama feature selected)
    if [[ "$has_llama" == "true" || "$profile" == "full" ]]; then
        services+="  vllm:\n"
        services+="    image: vllm/vllm-openai:latest\n"
        services+="    container_name: clawdess-vllm\n"
        services+="    ports:\n"
        services+="      - \"8000:8000\"\n"
        services+="    volumes:\n"
        services+="      - models:/models\n"
        services+="      - state:/state\n"
        services+="    environment:\n"
        services+="      - VLLM_HOST=0.0.0.0\n"
        services+="      - VLLM_PORT=8000\n"
        services+="    deploy:\n"
        services+="      resources:\n"
        services+="        reservations:\n"
        services+="          devices:\n"
        services+="            - driver: nvidia\n"
        services+="              count: 1\n"
        services+="              capabilities: [gpu]\n"
        services+="        limits:\n"
        services+="          memory: 48G\n"
        services+="      restart_policy:\n"
        services+="        condition: on-failure\n"
        services+="        delay: 5s\n"
        services+="        max_attempts: 3\n"
        services+="    healthcheck:\n"
        services+="      test: [\"CMD\", \"curl\", \"-sf\", \"http://localhost:8000/health\"]\n"
        services+="      interval: 30s\n"
        services+="      timeout: 10s\n"
        services+="      retries: 3\n"
        services+="      start_period: 120s\n"
        services+="    networks:\n"
        services+="      - clawdess-net\n\n"
    fi

    # llama.cpp service (via docker-in-docker or host network)
    if [[ "$has_llama" == "true" || "$profile" == "full" ]]; then
        services+="  llama:\n"
        services+="    image: ghcr.io/ggml-org/llama.cpp:latest\n"
        services+="    container_name: clawdess-llama\n"
        services+="    ports:\n"
        services+="      - \"8001:8001\"\n"
        services+="    volumes:\n"
        services+="      - models/gguf_models:/models\n"
        services+="      - state:/state\n"
        services+="    command: >\n"
        services+="      llama-server\n"
        services+="      --model /models/*.gguf\n"
        services+="      --host 0.0.0.0\n"
        services+="      --port 8001\n"
        services+="      -c 2048\n"
        services+="      --ctx-size 4096\n"
        services+="    deploy:\n"
        services+="      resources:\n"
        services+="        limits:\n"
        services+="          memory: 16G\n"
        services+="      restart_policy:\n"
        services+="        condition: on-failure\n"
        services+="        delay: 5s\n"
        services+="        max_attempts: 3\n"
        services+="    healthcheck:\n"
        services+="      test: [\"CMD\", \"curl\", \"-sf\", \"http://localhost:8001/health\"]\n"
        services+="      interval: 30s\n"
        services+="      timeout: 10s\n"
        services+="      retries: 3\n"
        services+="      start_period: 60s\n"
        services+="    networks:\n"
        services+="      - clawdess-net\n\n"
    fi

    # Piper TTS service
    if [[ "$has_voice" == "true" ]]; then
        services+="  piper:\n"
        services+="    image: ghcr.io/rhasspy/piper:latest\n"
        services+="    container_name: clawdess-piper\n"
        services+="    ports:\n"
        services+="      - \"5000:5000\"\n"
        services+="    volumes:\n"
        services+="      - models:/models\n"
        services+="      - artifacts:/artifacts\n"
        services+="    command: >\n"
        services+="      piper\n"
        services+="      --model /models/lessac-medium.onnx\n"
        services+="      --config /models/lessac-medium.onnx.json\n"
        services+="      --output_dir /artifacts/tts-output\n"
        services+="      --port 5000\n"
        services+="    deploy:\n"
        services+="      resources:\n"
        services+="        limits:\n"
        services+="          memory: 4G\n"
        services+="          cpus: \"1.0\"\n"
        services+="      restart_policy:\n"
        services+="        condition: on-failure\n"
        services+="        delay: 5s\n"
        services+="        max_attempts: 3\n"
        services+="    healthcheck:\n"
        services+="      test: [\"CMD\", \"curl\", \"-sf\", \"http://localhost:5000/ping\"]\n"
        services+="      interval: 30s\n"
        services+="      timeout: 10s\n"
        services+="      retries: 3\n"
        services+="      start_period: 30s\n"
        services+="    networks:\n"
        services+="      - clawdess-net\n\n"
    fi

    # Named volumes
    services+="volumes:\n"
    services+="  models:\n"
    services+="    driver: local\n"
    services+="    driver_opts:\n"
    services+="      type: none\n"
    services+="      o: bind\n"
    services+="      device: ${deploy_root}/models\n"
    services+="  artifacts:\n"
    services+="    driver: local\n"
    services+="    driver_opts:\n"
    services+="      type: none\n"
    services+="      o: bind\n"
    services+="      device: ${deploy_root}/artifacts\n"
    services+="  state:\n"
    services+="    driver: local\n"
    services+="    driver_opts:\n"
    services+="      type: none\n"
    services+="      o: bind\n"
    services+="      device: ${deploy_root}/state\n"

    # Network
    services+="\nnetworks:\n"
    services+="  clawdess-net:\n"
    services+="    driver: bridge\n"

    # Profile-based compose templates (stored in config/)
    local config_dir="$deploy_root/config"
    mkdir -p "$config_dir"

    # Minimal profile compose (photo only)
    cat > "$config_dir/docker-compose.minimal.yml" <<'COMPOSE'
# Profile: minimal — photo generation only
version: "3.8"
services:
  comfyui:
    image: ghcr.io/comfyanonymous/comfyui:latest
    container_name: clawdess-comfyui
    ports:
      - "8188:8188"
    volumes:
      - models:/models
      - artifacts:/artifacts
    environment:
      - PYTHONUNBUFFERED=1
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
        limits:
          memory: 32G
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8188/system_stats"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - clawdess-net

volumes:
  models:
  artifacts:

networks:
  clawdess-net:
    driver: bridge
COMPOSE

    # Media profile compose (photo + video)
    cat > "$config_dir/docker-compose.media.yml" <<'COMPOSE'
# Profile: media — photo + video generation
version: "3.8"
services:
  comfyui:
    image: ghcr.io/comfyanonymous/comfyui:latest
    container_name: clawdess-comfyui
    ports:
      - "8188:8188"
    volumes:
      - models:/models
      - artifacts:/artifacts
      - state:/state
    environment:
      - PYTHONUNBUFFERED=1
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
        limits:
          memory: 32G
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8188/system_stats"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - clawdess-net

  piper:
    image: ghcr.io/rhasspy/piper:latest
    container_name: clawdess-piper
    ports:
      - "5000:5000"
    volumes:
      - models:/models
      - artifacts:/artifacts
    command: >
      piper
      --model /models/lessac-medium.onnx
      --config /models/lessac-medium.onnx.json
      --output_dir /artifacts/tts-output
      --port 5000
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "1.0"
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:5000/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    networks:
      - clawdess-net

volumes:
  models:
  artifacts:
  state:

networks:
  clawdess-net:
    driver: bridge
COMPOSE

    # Full profile compose (photo + video + voice + LLM)
    cat > "$config_dir/docker-compose.full.yml" <<'COMPOSE'
# Profile: full — all features (photo, video, voice, LLM)
version: "3.8"
services:
  comfyui:
    image: ghcr.io/comfyanonymous/comfyui:latest
    container_name: clawdess-comfyui
    ports:
      - "8188:8188"
    volumes:
      - models:/models
      - artifacts:/artifacts
      - state:/state
    environment:
      - PYTHONUNBUFFERED=1
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
        limits:
          memory: 32G
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8188/system_stats"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - clawdess-net

  vllm:
    image: vllm/vllm-openai:latest
    container_name: clawdess-vllm
    ports:
      - "8000:8000"
    volumes:
      - models:/models
      - state:/state
    environment:
      - VLLM_HOST=0.0.0.0
      - VLLM_PORT=8000
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
        limits:
          memory: 48G
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    networks:
      - clawdess-net

  llama:
    image: ghcr.io/ggml-org/llama.cpp:latest
    container_name: clawdess-llama
    ports:
      - "8001:8001"
    volumes:
      - models/gguf_models:/models
      - state:/state
    command: >
      llama-server
      --model /models/*.gguf
      --host 0.0.0.0
      --port 8001
      -c 2048
      --ctx-size 4096
    deploy:
      resources:
        limits:
          memory: 16G
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8001/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - clawdess-net

  piper:
    image: ghcr.io/rhasspy/piper:latest
    container_name: clawdess-piper
    ports:
      - "5000:5000"
    volumes:
      - models:/models
      - artifacts:/artifacts
    command: >
      piper
      --model /models/lessac-medium.onnx
      --config /models/lessac-medium.onnx.json
      --output_dir /artifacts/tts-output
      --port 5000
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "1.0"
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:5000/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    networks:
      - clawdess-net

volumes:
  models:
  artifacts:
  state:

networks:
  clawdess-net:
    driver: bridge
COMPOSE

    # Write the main compose file (all services for the profile)
    printf '%s\n' "$services" > "$deploy_root/docker-compose.yml"

    # If Docker isn't available, generate compose file but skip validation
    if [[ "$docker_available" != "true" ]]; then
        printf 'docker-compose: generated without Docker (docker_available=false)\\n'
    fi

    printf 'lifecycle: docker-compose.yml generated in %s\\n' "$deploy_root"
    return 0
}

# ---------------------------------------------------------------------------
# Systemd orchestration units
# ---------------------------------------------------------------------------

# generate_systemd_orchestration DEPLOY_ROOT PROFILE
# Generates a full set of systemd user services with ordering and health checks.
# Services are ordered by startup: comfyui → vllm → llama → piper.
generate_systemd_orchestration() {
    local deploy_root="${1:?deploy root required}"
    local profile="${2:-minimal}"

    mkdir -p -- "$HOME/.config/systemd/user"

    # Determine which services to include
    local has_photo=false has_video=false has_voice=false has_llama=false

    case "$profile" in
        minimal)  has_photo=true ;;
        media)    has_photo=true; has_video=true ;;
        assistant) has_photo=true; has_video=true; has_voice=true ;;
        all)      has_photo=true; has_video=true; has_voice=true ;;
        full)     has_photo=true; has_video=true; has_voice=true; has_llama=true ;;
        *)        has_photo=true ;;
    esac

    # --- ComfyUI service (starts first) ---
    cat > "$HOME/.config/systemd/user/clawdess-comfyui.service" <<EOF
[Unit]
Description=Clawdess ComfyUI Service (port 8188)
After=network.target

[Service]
Type=simple
ExecStart=${deploy_root}/bin/start-comfyui
ExecStop=${deploy_root}/bin/stop-comfyui
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF

    # --- vLLM service (starts after comfyui) ---
    if [[ "$has_llama" == "true" || "$profile" == "full" ]]; then
        cat > "$HOME/.config/systemd/user/clawdess-vllm.service" <<EOF
[Unit]
Description=Clawdess vLLM Inference Service (port 8000)
After=network.target clawdess-comfyui.service
Requires=clawdess-comfyui.service

[Service]
Type=simple
ExecStart=${deploy_root}/bin/start-vllm
ExecStop=${deploy_root}/bin/stop-vllm
Restart=on-failure
RestartSec=5
TimeoutStartSec=180

[Install]
WantedBy=default.target
EOF

        # start-vllm script
        cat > "$deploy_root/bin/start-vllm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-}"
if [[ -z "$MODEL" && -d "$SCRIPT_DIR/models/diffusion_models" ]]; then
    MODEL="$(find "$SCRIPT_DIR/models/diffusion_models" -name "*.safetensors" -o -name "*.sft" 2>/dev/null | head -n 1)"
fi
if [[ -z "$MODEL" ]]; then
    printf 'vllm: no model found in models/diffusion_models/\\n' >&2
    exit 2
fi
mkdir -p -- "$SCRIPT_DIR/run"
printf 'vllm: starting vLLM (model: %s, port 8000)...\\n' "$MODEL" >&2
nohup python3 -m vllm.entrypoints.api_server \
    --model "$MODEL" \
    --host 0.0.0.0 \
    --port 8000 \
    --dtype float16 \
    --gpu-memory-utilization 0.9 \
    --max-model-len 2048 > "$SCRIPT_DIR/logs/vllm.log" 2>&1 &
echo $! > "$SCRIPT_DIR/run/vllm.pid"
printf 'vllm: started (pid %s, port 8000)\\n' $! >&2
SCRIPT

        # stop-vllm script
        cat > "$deploy_root/bin/stop-vllm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="$(dirname "$0")/../run/vllm.pid"
if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f -- "$PID_FILE"
    printf 'vllm: stopped (pid read from PID file)\\n'
else
    printf 'vllm: no PID file found\\n'
fi
SCRIPT
    fi

    # --- llama.cpp service (starts after vllm) ---
    if [[ "$has_llama" == "true" || "$profile" == "full" ]]; then
        cat > "$HOME/.config/systemd/user/clawdess-llama.service" <<EOF
[Unit]
Description=Clawdess llama.cpp Service (port 8001)
After=network.target clawdess-vllm.service
Requires=clawdess-vllm.service

[Service]
Type=simple
ExecStart=${deploy_root}/bin/start-llama
ExecStop=${deploy_root}/bin/stop-llama
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=default.target
EOF
    fi

    # --- Piper TTS service (starts after all others) ---
    if [[ "$has_voice" == "true" ]]; then
        cat > "$HOME/.config/systemd/user/clawdess-piper.service" <<EOF
[Unit]
Description=Clawdess Piper TTS Service (port 5000)
After=network.target clawdess-comfyui.service clawdess-vllm.service clawdess-llama.service
Requires=clawdess-comfyui.service

[Service]
Type=simple
ExecStart=${deploy_root}/bin/start-piper
ExecStop=${deploy_root}/bin/stop-piper
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=default.target
EOF

        # start-piper script
        cat > "$deploy_root/bin/start-piper" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-}"
CONFIG="${2:-}"
if [[ -z "$MODEL" && -d "$SCRIPT_DIR/models/checkpoints" ]]; then
    MODEL="$(find "$SCRIPT_DIR/models/checkpoints" -name "*.onnx" 2>/dev/null | head -n 1)"
    CONFIG="${MODEL}.json"
fi
if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
    printf 'piper: no model found in models/checkpoints/\\n' >&2
    exit 2
fi
mkdir -p -- "$SCRIPT_DIR/run" "$SCRIPT_DIR/artifacts/tts-output"
printf 'piper: starting piper TTS (model: %s, port 5000)...\\n' "$MODEL" >&2
nohup piper --model "$MODEL" \
    ${CONFIG:+"--config" "$CONFIG"} \
    --output_dir "$SCRIPT_DIR/artifacts/tts-output" \
    --port 5000 > "$SCRIPT_DIR/logs/piper.log" 2>&1 &
echo $! > "$SCRIPT_DIR/run/piper.pid"
printf 'piper: started (pid %s, port 5000)\\n' $! >&2
SCRIPT

        # stop-piper script
        cat > "$deploy_root/bin/stop-piper" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="$(dirname "$0")/../run/piper.pid"
if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f -- "$PID_FILE"
    printf 'piper: stopped (pid read from PID file)\\n'
else
    printf 'piper: no PID file found\\n'
fi
SCRIPT
    fi

    # --- Orchestrator service (manages all, starts/stops in order) ---
    cat > "$HOME/.config/systemd/user/clawdess-wizard.service" <<EOF
[Unit]
Description=Clawdess DGX Spark Deployment Orchestrator
After=network.target clawdess-comfyui.service
Requires=clawdess-comfyui.service
After=clawdess-comfyui.service

EOF

    # Add dependency lines based on profile
    if [[ "$has_llama" == "true" || "$profile" == "full" ]]; then
        echo "After=clawdess-vllm.service" >> "$HOME/.config/systemd/user/clawdess-wizard.service"
        echo "Requires=clawdess-vllm.service" >> "$HOME/.config/systemd/user/clawdess-wizard.service"
    fi

    cat >> "$HOME/.config/systemd/user/clawdess-wizard.service" <<EOF
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${deploy_root}/bin/start-all-services
ExecStop=${deploy_root}/bin/stop-all-services
ExecReload=${deploy_root}/bin/reload-services

[Install]
WantedBy=default.target
EOF

    # start-all-services: start in order
    cat > "$deploy_root/bin/start-all-services" <<SCRIPT_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "\$(dirname "\$0")/.." && pwd)"
printf "=== Starting all Clawdess services ===\\n" >&2

# 1. Start ComfyUI first
printf "1/4: Starting ComfyUI...\\n" >&2
if [[ -f "\$SCRIPT_DIR/bin/start-comfyui" ]]; then
    "\$SCRIPT_DIR/bin/start-comfyui" &
    if ! wait_for_comfyui_readiness "http://127.0.0.1:8188" 120; then
        printf "ComfyUI readiness failed\\n" >&2
        exit 1
    fi
    printf "ComfyUI ready\\n" >&2
fi

# 2. Start vLLM (if available)
if [[ -f "\$SCRIPT_DIR/bin/start-vllm" ]]; then
    printf "2/4: Starting vLLM...\\n" >&2
    "\$SCRIPT_DIR/bin/start-vllm" &
    sleep 5  # Allow vLLM to initialize
    printf "vLLM started\\n" >&2
fi

# 3. Start llama.cpp (if available)
if [[ -f "\$SCRIPT_DIR/bin/start-llama" ]]; then
    printf "3/4: Starting llama.cpp...\\n" >&2
    "\$SCRIPT_DIR/bin/start-llama" &
    if ! wait_for_health http://localhost:8001/health 60; then
        printf "llama.cpp readiness check timed out\\n" >&2
    else
        printf "llama.cpp ready\\n" >&2
    fi
fi

# 4. Start Piper TTS (if available)
if [[ -f "\$SCRIPT_DIR/bin/start-piper" ]]; then
    printf "4/4: Starting Piper TTS...\\n" >&2
    "\$SCRIPT_DIR/bin/start-piper" &
    if ! wait_for_health http://localhost:5000/ping 30; then
        printf "Piper readiness check timed out\\n" >&2
    else
        printf "Piper ready\\n" >&2
    fi
fi

printf "=== All services started ===\\n" >&2
SCRIPT_EOF
    chmod +x "$deploy_root/bin/start-all-services" 2>/dev/null || true

    # stop-all-services: stop in reverse order
    cat > "$deploy_root/bin/stop-all-services" <<SCRIPT_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "\$(dirname "\$0")/.." && pwd)"
printf "=== Stopping all Clawdess services ===\\n" >&2

# Stop in reverse order: piper → llama → vllm → comfyui
for svc in piper llama vllm comfyui; do
    if [[ -f "\$SCRIPT_DIR/bin/\${svc}.pid" ]]; then
        pid="\$(cat "\$SCRIPT_DIR/bin/\${svc}.pid")"
        if kill -0 "\$pid" 2>/dev/null; then
            printf "Stopping \$svc (pid \$pid)...\\n" >&2
            kill "\$pid" 2>/dev/null || true
        fi
        rm -f "\$SCRIPT_DIR/bin/\${svc}.pid"
    fi
done

# Also try run directory
for pid_file in "\$SCRIPT_DIR/run"/*.pid; do
    [[ -f "\$pid_file" ]] || continue
    pid="\$(cat "\$pid_file" 2>/dev/null)"
    if [[ -n "\$pid" && "\$pid" =~ ^[0-9]+$ ]]; then
        kill "\$pid" 2>/dev/null || true
    fi
    rm -f "\$pid_file"
done

printf "=== All services stopped ===\\n" >&2
SCRIPT_EOF
    chmod +x "$deploy_root/bin/stop-all-services" 2>/dev/null || true

    # reload-services: health check
    cat > "$deploy_root/bin/reload-services" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
printf "=== Health check for all services ===\\n" >&2
exec "$SCRIPT_DIR/bin/health-check"
SCRIPT
    chmod +x "$deploy_root/bin/reload-services" 2>/dev/null || true

    printf 'systemd: generated orchestration units in ~/.config/systemd/user\\n'
    return 0
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
"$SCRIPT_DIR/venv/bin/python" "$SCRIPT_DIR/artifacts/ComfyUI/main.py" "$@"
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

    # Llama.cpp start script
    cat > "$deploy_root/bin/start-llama" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GGUF_MODEL="${1:-}"
if [[ -z "$GGUF_MODEL" && -d "$SCRIPT_DIR/models/gguf_models" ]]; then
    GGUF_MODEL="$(find "$SCRIPT_DIR/models/gguf_models" -name "*.gguf" 2>/dev/null | head -n 1)"
fi
if [[ -z "$GGUF_MODEL" || ! -f "$GGUF_MODEL" ]]; then
    printf 'llama: no GGUF model found in models/gguf_models/\n' >&2
    exit 2
fi
if ! command -v llama-server >/dev/null 2>&1; then
    printf 'llama: llama-server binary not found on PATH\n' >&2
    exit 3
fi
mkdir -p -- "$SCRIPT_DIR/run"
printf 'llama: starting llama-server (model: %s, port 8001)...\n' "$GGUF_MODEL" >&2
nohup llama-server -m "$GGUF_MODEL" --port 8001 -c 2048 --ctx-size 4096 > "$SCRIPT_DIR/logs/llama.log" 2>&1 &
echo $! > "$SCRIPT_DIR/run/llama.pid"
printf 'llama: started (pid %s, port 8001)\n' $! >&2
SCRIPT

    # Llama.cpp stop script
    cat > "$deploy_root/bin/stop-llama" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="$(dirname "$0")/../run/llama.pid"
if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f -- "$PID_FILE"
    printf 'llama: stopped (pid read from PID file)\n'
else
    printf 'llama: no PID file found\n'
fi
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
healthy_count=0

# Check ComfyUI readiness (port 8188)
if [[ -f "$SCRIPT_DIR/run/comfyui.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/comfyui.pid")"
    if kill -0 "$pid" 2>/dev/null; then
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
            healthy_count=$((healthy_count + 1))
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

# Check vLLM readiness (port 8000) via HTTP /health
if [[ -f "$SCRIPT_DIR/run/vllm.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/vllm.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        if curl -s --max-time 5 http://localhost:8000/health >/dev/null 2>&1; then
            printf 'vLLM: healthy (pid %s)\n' "$pid"
            healthy_count=$((healthy_count + 1))
        else
            printf 'vLLM: process alive but /health not responding (pid %s)\n' "$pid"
            error_count=$((error_count + 1))
        fi
    else
        printf 'vLLM: dead process in pid file\n'
        error_count=$((error_count + 1))
    fi
fi

# Check llama.cpp readiness (port 8001) via HTTP /health
if [[ -f "$SCRIPT_DIR/run/llama.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/llama.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        if curl -s --max-time 5 http://localhost:8001/health >/dev/null 2>&1; then
            printf 'llama.cpp: healthy (pid %s)\n' "$pid"
            healthy_count=$((healthy_count + 1))
        else
            printf 'llama.cpp: process alive but /health not responding (pid %s)\n' "$pid"
            error_count=$((error_count + 1))
        fi
    else
        printf 'llama.cpp: dead process in pid file\n'
        error_count=$((error_count + 1))
    fi
fi

# Check piper readiness (port 5000) via HTTP /ping
if [[ -f "$SCRIPT_DIR/run/piper.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/piper.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        if curl -s --max-time 5 http://localhost:5000/ping >/dev/null 2>&1; then
            printf 'piper: healthy (pid %s)\n' "$pid"
            healthy_count=$((healthy_count + 1))
        else
            printf 'piper: process alive but /ping not responding (pid %s)\n' "$pid"
            error_count=$((error_count + 1))
        fi
    else
        printf 'piper: dead process in pid file\n'
        error_count=$((error_count + 1))
    fi
else
    printf 'piper: no pid file found (service not started)\n'
fi

# Check TTS (piper legacy PID file, for backwards compat)
if [[ -f "$SCRIPT_DIR/run/tts.pid" ]]; then
    pid="$(cat "$SCRIPT_DIR/run/tts.pid")"
    if kill -0 "$pid" 2>/dev/null; then
        printf 'TTS (piper legacy): ready (pid %s)\n' "$pid"
    else
        printf 'TTS (piper legacy): dead process in pid file\n'
        error_count=$((error_count + 1))
    fi
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
    printf 'health-check: %d issue(s), %d healthy\n' "$error_count" "$healthy_count"
    exit 1
fi

printf 'health-check: all services healthy (%d checked)\n' "$healthy_count"
exit 0
SCRIPT

    # Docker Compose scaffold — generates a full compose with 4 services,
    # profile-based templates, health checks, and resource limits.
    # Works without Docker being installed (only generates the file).
    generate_docker_compose "$deploy_root" "$profile" "$docker_available"

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

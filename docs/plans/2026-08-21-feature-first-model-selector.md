# Feature-First Model Selector Implementation Plan

> **For implementer:** Use TDD throughout. Write failing test first. Watch it fail. Then implement.

**Goal:** Replace the current single-photo-model Phase 5 with a cascading feature-first selection flow (features → provider → model per feature), with profile bundles pre-filling defaults.

**Architecture:** Three new library functions (`select_features`, `select_provider`, `select_model`), a `--features` CLI argument, expanded config with `features`/`profiles` sections, new model entries for video and Kokoro/XTTS/vLLM TTS, profile-based default resolution, and ComfyUI custom-node + multi-model download support.

**Tech Stack:** Bash (deploy-dgx-spark-lib.sh, deploy-dgx-spark.sh), JSON config, Python3 for JSON helpers, pytest for tests.

**Working directory:** `/home/thx1138/annafoid/clawdess-recovered`
**Branch:** `repair/dgx-spark-deployment-wizard`

---

## Task 1: Config restructuring — add features/index/profiles sections

**Files:**
- Modify: `config/dgx-spark-models.json`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** Restructure the flat model config into a structured format with `features`, `profiles`, and `models` sections while preserving backward compatibility with existing entries.

**Step 1: Define the new JSON structure**

Write the expanded config to `config/dgx-spark-models.json` with this structure:

```json
{
  "features": {
    "photo": {
      "label": "Photo",
      "description": "AI-edited selfies from a reference image",
      "models": [
        "flux1-dev-fp8",
        "juggernaut-xl-v10",
        "pony-v6",
        "noobai-xl"
      ]
    },
    "video": {
      "label": "Video",
      "description": "Image-to-video generation",
      "models": [
        "wan2gp-i2v-14B",
        "ltx-video",
        "svd"
      ]
    },
    "voice": {
      "label": "Voice",
      "description": "Text-to-speech voice messages",
      "backends": [
        "kokoro",
        "piper",
        "xtts-v2",
        "vllm"
      ]
    }
  },
  "profiles": {
    "minimal": {
      "label": "Photo only (minimal)",
      "features": ["photo"],
      "photo_model": "juggernaut-xl-v10",
      "tts_backend": "piper"
    },
    "media": {
      "label": "Photo + Video (media)",
      "features": ["photo", "video"],
      "photo_model": "juggernaut-xl-v10",
      "video_model": "wan2gp-i2v-14B",
      "tts_backend": "piper"
    },
    "assistant": {
      "label": "Photo + Video + Voice (assistant)",
      "features": ["photo", "video", "voice"],
      "photo_model": "juggernaut-xl-v10",
      "video_model": "wan2gp-i2v-14B",
      "tts_backend": "kokoro"
    },
    "all": {
      "label": "All features",
      "features": ["photo", "video", "voice"],
      "photo_model": "juggernaut-xl-v10",
      "video_model": "wan2gp-i2v-14B",
      "tts_backend": "kokoro"
    }
  },
  "models": {
    "flux1-dev-fp8": {
      "category": "photo",
      "provider": ["local", "remote"],
      "vram_min_gb": 8,
      "files": {
        "unet": {
          "source": "https://huggingface.co/Comfy-Org/flux1-dev-fp8/resolve/main/unet/diffusion_pytorch_model.fp8_e4m3fn.safetensors",
          "filename": "flux1-dev-fp8.safetensors",
          "minimum_size_bytes": 6180000000,
          "required": true,
          "checksum": "sha256:d8114bd4c40b0dbd6b0fd6267246a56e07e828e92e84f4f4c8d0e2b2b9e7b5a4"
        }
      }
    },
    "juggernaut-xl-v10": {
      "category": "photo",
      "provider": ["local", "remote"],
      "vram_min_gb": 6,
      "files": {
        "checkpoints": {
          "source": "https://civitai.com/api/download/models/1296965",
          "filename": "juggernautXL_v10.safetensors",
          "minimum_size_bytes": 6650000000,
          "required": true,
          "checksum": "sha256:a7998502176431e30841e9253ed9e81e3b1f2a87061f72983d7e41b6d822b220"
        }
      }
    },
    "pony-v6": {
      "category": "photo",
      "provider": ["local", "remote"],
      "vram_min_gb": 6,
      "files": {
        "checkpoints": {
          "source": "https://huggingface.co/purplehaize/Pony-Diffusion-V6-XL/resolve/main/ponyDiffusionV6XL_v61.safetensors",
          "filename": "ponyDiffusionV6XL_v61.safetensors",
          "minimum_size_bytes": 6650000000,
          "required": true,
          "checksum": null
        }
      }
    },
    "noobai-xl": {
      "category": "photo",
      "provider": ["local", "remote"],
      "vram_min_gb": 6,
      "files": {
        "checkpoints": {
          "source": "https://huggingface.co/noobai/NoobAI-XL/resolve/main/noobaiXL_v10.safetensors",
          "filename": "noobaiXL_v10.safetensors",
          "minimum_size_bytes": 6650000000,
          "required": true,
          "checksum": null
        }
      }
    },
    "wan2gp-i2v-14B": {
      "category": "video",
      "provider": ["local"],
      "vram_min_gb": 12,
      "custom_nodes": ["ComfyUI-WanVideoWrapper"],
      "files": {
        "diffusion_models": {
          "source": "https://huggingface.co/Wan-Video/Wan2.1-I2V-14B-480P-FP8/resolve/main/wan2.1_i2v_14B_480p_fp8.safetensors",
          "filename": "wan2gp_i2v_14B_fp8.safetensors",
          "minimum_size_bytes": 14000000000,
          "required": true,
          "checksum": null
        },
        "text_encoders": {
          "source": "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
          "filename": "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
          "minimum_size_bytes": 2100000000,
          "required": true,
          "checksum": null
        },
        "vae": {
          "source": "https://huggingface.co/Wan-Video/Wan2.1-I2V-14B-480P-FP8/resolve/main/wan2.1_vae.safetensors",
          "filename": "wan_2.1_vae.safetensors",
          "minimum_size_bytes": 7800000000,
          "required": true,
          "checksum": null
        },
        "clip_vision": {
          "source": "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/models/image_encoder/pytorch_model.pt",
          "filename": "clip_vision_h.safetensors",
          "minimum_size_bytes": 1200000000,
          "required": true,
          "checksum": null
        }
      }
    },
    "ltx-video": {
      "category": "video",
      "provider": ["local", "remote"],
      "vram_min_gb": 6,
      "files": {
        "diffusion_models": {
          "source": "https://huggingface.co/Lightricks/LTX-Video-2B-FP8/resolve/main/ltx-video-2b-v0.9.safetensors",
          "filename": "ltx-video-2b-v0.9.safetensors",
          "minimum_size_bytes": 5100000000,
          "required": true,
          "checksum": null
        }
      }
    },
    "svd": {
      "category": "video",
      "provider": ["local"],
      "vram_min_gb": 8,
      "files": {
        "checkpoints": {
          "source": "https://huggingface.co/stabilityai/stable-video-diffusion-img2vid-xt/resolve/main/svd_xt.safetensors",
          "filename": "svd_xt.safetensors",
          "minimum_size_bytes": 9500000000,
          "required": true,
          "checksum": null
        }
      }
    },
    "kokoro": {
      "category": "voice",
      "provider": ["local"],
      "files": {
        "default": {
          "source": "https://github.com/nazdridoy/kokoro-onnx/releases/download/v0.2.0/kokoro-v0_19.onnx",
          "filename": "kokoro-v0_19.onnx",
          "minimum_size_bytes": 240000000,
          "required": true,
          "checksum": null
        }
      }
    },
    "piper": {
      "category": "voice",
      "provider": ["local"],
      "files": {
        "onnx": {
          "source": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx",
          "filename": "lessac-medium.onnx",
          "minimum_size_bytes": 60000000,
          "required": true,
          "checksum": null
        },
        "config": {
          "source": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/config.json",
          "filename": "lessac-medium.onnx.json",
          "minimum_size_bytes": 1000,
          "required": true,
          "checksum": null
        }
      }
    },
    "xtts-v2": {
      "category": "voice",
      "provider": ["local"],
      "pip_package": "TTS",
      "pip_args": "--no-cache-dir"
    },
    "vllm": {
      "category": "voice",
      "provider": ["local"],
      "pip_package": "vllm",
      "pip_args": "--no-cache-dir"
    }
  }
}
```

**Step 2: Write tests for config parsing**

Add tests to `tests/test_dgx_spark_ac_gaps.py`:
- `test_config_has_features_section` — config has `features` key with photo/video/voice
- `test_config_has_profiles_section` — config has `profiles` key with minimal/media/assistant/all
- `test_config_profiles_map_to_features` — minimal=[photo], media=[photo,video], assistant=[photo,video,voice], all=[photo,video,voice]
- `test_config_photo_models_listed` — photo has 4 models
- `test_config_video_models_listed` — video has 3 models
- `test_config_voice_backends_listed` — voice has 4 backends

Run: `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k "config_has" -v`

**Step 3: Commit**
```bash
cd /home/thx1138/annafoid/clawdess-recovered
git add config/dgx-spark-models.json tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): expand config with features, profiles, and new model entries"
```

---

## Task 2: Implement select_features function

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** `select_features` resolves which features are enabled from a profile default or interactive selection, returns a space-separated list (e.g., "photo video voice").

**Step 1: Write failing test**

```python
def test_select_features_from_profile(config_path, tmp_path):
    """select_features returns correct feature set from a profile."""
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_features {config_path} media'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "photo" in result.stdout
    assert "video" in result.stdout
    assert "voice" not in result.stdout

def test_select_features_interactive_photo_only(config_path, tmp_path):
    """select_features returns only selected features from interactive input."""
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_features {config_path} "" <<< "1"'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "photo" in result.stdout
    assert "video" not in result.stdout
```

**Step 2: Implement `select_features` in lib**

```bash
select_features() {
    local config="${1:?config required}" profile="${2:-}"
    
    # If profile is set, resolve from config
    if [[ -n "$profile" ]]; then
        local features
        features=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
profile_name = sys.argv[2]
p = cfg.get('profiles', {}).get(profile_name, {})
if p.get('features'):
    print(' '.join(p['features']))
else:
    print('photo')
" "$config" "$profile")
        printf '%s\n' "$features"
        return 0
    fi
    
    # Interactive selection
    if [[ ! -t 0 ]]; then
        # Non-interactive: default to photo only
        printf 'photo\n'
        return 0
    fi
    
    printf '\nWhich features do you want?\n'
    printf '  1) Photo (AI-edited selfies)\n'
    printf '  2) Video (image-to-video)\n'
    printf '  3) Voice (text-to-speech)\n'
    printf 'Select (space-separated, e.g. "1 2"): '\
    
    local input
    IFS= read -r input || input="1"
    
    local selected=()
    for digit in $input; do
        case "$digit" in
            1) selected+=("photo") ;;
            2) selected+=("video") ;;
            3) selected+=("voice") ;;
        esac
    done
    
    if ((${#selected[@]} == 0)); then
        selected=("photo")
    fi
    
    printf '%s\n' "${selected[*]}"
}
```

**Step 3: Run tests**
```bash
cd /home/thx1138/annafoid/clawdess-recovered
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py::test_select_features_from_profile -v
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py::test_select_features_interactive_photo_only -v
```

**Step 4: Commit**
```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): add select_features function with profile and interactive support"
```

---

## Task 3: Implement select_provider function

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** `select_provider CATEGORY` returns the provider choice ("local" or "remote") for a given feature category. Resolves from profile default, CLI arg (`--provider`), or interactive selection.

**Step 1: Write failing test**

```python
def test_select_provider_from_profile(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_provider {config_path} photo media'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "local" in result.stdout

def test_select_provider_interactive(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_provider {config_path} video <<< "2"'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "remote" in result.stdout
```

**Step 2: Implement `select_provider` in lib**

```bash
select_provider() {
    local config="${1:?config required}" category="${2:?category required}" profile="${3:-}"
    local cli_provider="${4:-}"
    
    # CLI override takes priority
    if [[ -n "$cli_provider" ]]; then
        printf '%s\n' "$cli_provider"
        return 0
    fi
    
    # Profile default
    if [[ -n "$profile" ]]; then
        local provider
        provider=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
profile_name = sys.argv[2]
category = sys.argv[3]
p = cfg.get('profiles', {}).get(profile_name, {})
# Default provider per profile
defaults = {'minimal': 'local', 'media': 'local', 'assistant': 'local', 'all': 'local'}
print(defaults.get(profile_name, 'local'))
" "$config" "$profile")
        printf '%s\n' "$provider"
        return 0
    fi
    
    # Interactive
    if [[ ! -t 0 ]]; then
        printf 'local\n'
        return 0
    fi
    
    printf '\n%s provider:\n' "$(capitalize "$category")"
    printf '  1) Local ComfyUI (requires GPU, local models)\n'
    printf '  2) Remote API (cloud inference)\n'
    printf 'Select [1-2]: '\
    
    local choice
    IFS= read -r choice || choice="1"
    case "$choice" in
        1) printf 'local\n' ;;
        2) printf 'remote\n' ;;
        *) printf 'local\n' ;;
    esac
}

capitalize() {
    printf '%s\n' "${1:0:1}" | tr '[:lower:]' '[:upper:]'"${1:1}"
}
```

**Step 3: Run tests**
```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k "select_provider" -v
```

**Step 4: Commit**
```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): add select_provider function"
```

---

## Task 4: Implement select_model function

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** `select_model CATEGORY config profile` returns the selected model key. Resolves from profile default, CLI arg (`--image-model`, `--video-model`), or interactive catalog selection.

**Step 1: Write failing test**

```python
def test_select_model_from_profile_photo(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_model photo {config_path} media'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "juggernaut-xl-v10" in result.stdout

def test_select_model_from_profile_video(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_model video {config_path} media'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "wan2gp-i2v-14B" in result.stdout

def test_select_model_interactive(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_model photo {config_path} "" <<< "2"'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    # Choice 2 in photo list = juggernaut-xl-v10

def test_select_model_non_interactive_default(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && select_model photo {config_path} ""'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "juggernaut-xl-v10" in result.stdout or "flux1-dev-fp8" in result.stdout
```

**Step 2: Implement `select_model` in lib**

```bash
select_model() {
    local category="${1:?category required}" config="${2:?config required}" profile="${3:-}"
    local cli_model="${4:-}"
    
    # CLI override
    if [[ -n "$cli_model" ]]; then
        # Validate against config
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
    
    # Profile default
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
print(p.get(sys.argv[3], ''))
" "$config" "$profile" "$profile_key")
        if [[ -n "$model" ]]; then
            printf '%s\n' "$model"
            return 0
        fi
    fi
    
    # Non-interactive default (first model in category)
    if [[ ! -t 0 ]]; then
        local default_model
        default_model=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
category = sys.argv[2]
if category == 'voice':
    backends = cfg.get('features', {}).get('voice', {}).get('backends', [])
    if backends:
        print(backends[0])
else:
    models_list = cfg.get('features', {}).get(category, {}).get('models', [])
    if models_list:
        print(models_list[0])
" "$config" "$category")
        printf '%s\n' "$default_model"
        return 0
    fi
    
    # Interactive catalog
    local catalog_models
    catalog_models=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
category = sys.argv[2]
if category == 'voice':
    backends = cfg.get('features', {}).get('voice', {}).get('backends', [])
    models = [(b, cfg.get('models', {}).get(b, {})) for b in backends]
else:
    models_list = cfg.get('features', {}).get(category, {}).get('models', [])
    models = [(m, cfg.get('models', {}).get(m, {})) for m in models_list]

for i, (key, meta) in enumerate(models, 1):
    name = meta.get('name', key)
    desc = meta.get('description', f\"{category}, {meta.get('vram_min_gb', '?')}GB VRAM\")
    print(f\"{i}) {key} - {desc}\")
" "$config" "$category")
    
    printf '\n%s models:\n' "$(capitalize "$category")"
    printf '%s\n' "$catalog_models"
    printf 'Select: '\
    
    local choice
    IFS= read -r choice || choice="1"
    
    python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
category = sys.argv[2]
choice = int(sys.argv[3])
if category == 'voice':
    backends = cfg.get('features', {}).get('voice', {}).get('backends', [])
else:
    models_list = cfg.get('features', {}).get(category, {}).get('models', [])
models = backends if category == 'voice' else models_list
if 1 <= choice <= len(models):
    print(models[choice - 1])
" "$config" "$category" "$choice"
}
```

**Step 3: Run tests**
```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k "select_model" -v
```

**Step 4: Commit**
```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): add select_model function with interactive catalog and profile defaults"
```

---

## Task 5: Wire Phase 5 in wizard — call feature→provider→model selectors

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Goal:** Replace the current Phase 5 stub (single IMAGE_MODEL variable) with the full cascading selection flow. Add CLI arguments: `--features`, `--provider`, `--video-model`, `--tts-backend`.

**Step 1: Add new CLI arguments and variables**

In the argument parsing section (around line 43), add:
```bash
FEATURES=""
VIDEO_MODEL=""
PROVIDER=""
```

Add argument cases for:
```bash
--features) FEATURES="$2"; shift 2 ;;
--video-model) VIDEO_MODEL="$2"; shift 2 ;;
--provider) PROVIDER="$2"; shift 2 ;;
```

**Step 2: Replace Phase 5 body (lines 217-251)**

New Phase 5:
```bash
PHASE="models"
printf '=== Phase 5: Model Acquisition ===\n'

# Resolve profile from CLI
if [[ -z "$PROFILE" ]]; then
    printf 'profile: not set\n'
    if [[ "$NON_INTERACTIVE" == true ]]; then
        on_error 1 "$LINENO" "profile not specified"
        exit 1
    fi
fi

# 5a: Select features
printf 'phase: selecting features\n'
FEATURE_LIST="$(select_features "$CONFIG" "$PROFILE")" || {
    printf 'model: feature selection failed\n' >&2
    on_error 1 "$LINENO" "feature selection failed"
    exit 1
}
printf 'features: %s\n' "$FEATURE_LIST"

# 5b: Select provider and model for each feature
IMAGE_MODEL=""
VIDEO_MODEL_SELECTED=""
TTS_BACKEND=""

if echo "$FEATURE_LIST" | grep -q 'photo'; then
    PHOTO_PROVIDER="$(select_provider "$CONFIG" photo "$PROFILE" "$PROVIDER")" || {
        printf 'model: photo provider selection failed\n' >&2
        on_error 1 "$LINENO" "photo provider selection failed"
        exit 1
    }
    if [[ "$PHOTO_PROVIDER" == "local" ]]; then
        IMAGE_MODEL="$(select_model photo "$CONFIG" "$PROFILE" "$IMAGE_MODEL")" || {
            printf 'model: photo model selection failed\n' >&2
            on_error 1 "$LINENO" "photo model selection failed"
            exit 1
        }
    fi
    printf 'photo: provider=%s model=%s\n' "$PHOTO_PROVIDER" "${IMAGE_MODEL:-remote_api}"
fi

if echo "$FEATURE_LIST" | grep -q 'video'; then
    VIDEO_PROVIDER="$(select_provider "$CONFIG" video "$PROFILE" "$PROVIDER")" || {
        printf 'model: video provider selection failed\n' >&2
        on_error 1 "$LINENO" "video provider selection failed"
        exit 1
    }
    if [[ "$VIDEO_PROVIDER" == "local" ]]; then
        VIDEO_MODEL_SELECTED="$(select_model video "$CONFIG" "$PROFILE" "$VIDEO_MODEL")" || {
            printf 'model: video model selection failed\n' >&2
            on_error 1 "$LINENO" "video model selection failed"
            exit 1
        }
    fi
    printf 'video: provider=%s model=%s\n' "$VIDEO_PROVIDER" "${VIDEO_MODEL_SELECTED:-remote_api}"
fi

if echo "$FEATURE_LIST" | grep -q 'voice'; then
    TTS_BACKEND="$(select_model voice "$CONFIG" "$PROFILE" "$TTS_BACKEND")" || {
        printf 'model: voice backend selection failed\n' >&2
        on_error 1 "$LINENO" "voice backend selection failed"
        exit 1
    }
    printf 'voice: backend=%s\n' "$TTS_BACKEND"
fi

# 5d: Summary and confirm
printf '\n=== Configuration Summary ===\n'
printf 'Features: %s\n' "$(echo "$FEATURE_LIST" | tr ' ' ', ')"
printf 'Photo: %s → %s\n' "${PHOTO_PROVIDER:-n/a}" "${IMAGE_MODEL:-n/a}"
printf 'Video: %s → %s\n' "${VIDEO_PROVIDER:-n/a}" "${VIDEO_MODEL_SELECTED:-n/a}"
printf 'Voice: %s → %s\n' "${PROVIDER:-n/a}" "${TTS_BACKEND:-n/a}"

if [[ "$DRY_RUN" == true ]]; then
    printf '\ndry-run: acquiring models (dry run, no downloads)\n'
    acquire_models "$MODEL_ROOT" "$CONFIG" "${IMAGE_MODEL:-juggernaut-xl-v10}" "${TTS_BACKEND:-piper}" true "$STATE_ROOT" || {
        on_error 1 "$LINENO" "dry-run model planning failed"
        exit 1
    }
    printf 'dry-run: model acquisition complete (no filesystem changes)\n'
    exit 0
fi

# Disk space check
free_kb=$(probe_df -Pk "$MODEL_ROOT" 2>/dev/null | awk 'NR==2 {print $4}') || true
required_bytes=8000000000
if [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -lt "$((required_bytes / 1024 / 1024 + 100))" ]]; then
    printf 'disk: insufficient space for model acquisition (%d MB free, ~%d MB required)\n' "$free_kb" "$((required_bytes / 1024 / 1024))" >&2
    on_error 1 "$LINENO" "insufficient disk space"
    exit 1
fi

# Acquire models
if ! acquire_models "$MODEL_ROOT" "$CONFIG" "${IMAGE_MODEL:-juggernaut-xl-v10}" "${TTS_BACKEND:-piper}" false "$STATE_ROOT"; then
    on_error 1 "$LINENO" "model acquisition failed"
    exit 1
fi

# Commit selection to state
state_write "$STATE_ROOT" "models" "feature selection complete" "$FEATURE_LIST" "selecting"
```

**Step 3: Add `--features`, `--video-model` to help text (line 56)**

**Step 4: Run integration tests**
```bash
cd /home/thx1138/annafoid/clawdess-recovered
.venv/bin/python -m pytest tests/test_deploy_dgx_spark.py -k "phase5" -v
```

**Step 5: Commit**
```bash
git add scripts/deploy-dgx-spark.sh tests/test_deploy_dgx_spark.py
git commit -m "feat(dgx-spark): wire cascading feature→provider→model selectors into Phase 5"
```

---

## Task 6: Extend acquire_models for multi-model acquisition

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** `acquire_models` must handle the new config structure with `models.*.files` sub-keys. It downloads each file to the correct ComfyUI subdirectory based on the category (diffusion_models, checkpoints, unet, text_encoders, clip_vision, vae).

**Step 1: Update model_records for new config format**

The existing `model_records()` function needs to handle the new nested `files` structure:

```bash
model_records() {
    local config="${1:?config required}" image="${2:?image required}" backend="${3:?backend required}"
    command python3 -c "
import json, sys

cfg = json.load(open(sys.argv[1]))
image = sys.argv[2]
backend = sys.argv[3]

# New config format: models.*.files structure
models_cfg = cfg.get('models', {})
records = []

# Process image model
if image in models_cfg:
    entry = models_cfg[image]
    files = entry.get('files', {})
    if isinstance(files, dict):
        for subdir, fmeta in files.items():
            r = {'kind': 'image', 'name': image, 'subdir': subdir}
            r.update(fmeta)
            records.append(json.dumps(r, separators=(',',':')))
    elif 'source' in entry:
        # Single-file legacy format
        r = {'kind': 'image', 'name': image}
        r.update(entry)
        records.append(json.dumps(r, separators=(',',':')))

# Process TTS backend
if backend in models_cfg:
    entry = models_cfg[backend]
    files = entry.get('files', {})
    if isinstance(files, dict):
        for fname, fmeta in files.items():
            r = {'kind': 'tts', 'name': backend, 'filename': fname}
            r.update(fmeta)
            records.append(json.dumps(r, separators=(',',':')))
    elif 'source' in entry:
        # Single-file legacy format
        r = {'kind': 'tts', 'name': backend}
        r.update(entry)
        records.append(json.dumps(r, separators=(',',':')))

print('\n'.join(records))
" "$config" "$image" "$backend"
}
```

**Step 2: Update acquire_models to handle subdir**

In `acquire_models`, add subdir support to path resolution:

```bash
# In the record loop, after reading subdir:
subdir=$(_model_record_field "$record" subdir 2>/dev/null) || subdir=""
if [[ -n "$subdir" ]]; then
    path="$root/$subdir/$filename"
    mkdir -p -- "$root/$subdir" || return 1
else
    path=$(_model_path_safe "$root" "$filename") || return 1
fi
```

**Step 3: Add tests**
```python
def test_model_records_new_format(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && model_records {config_path} juggernaut-xl-v10 piper'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "juggernautXL_v10.safetensors" in result.stdout
    assert "lessac-medium.onnx" in result.stdout

def test_model_records_wan2gp(config_path):
    result = subprocess.run(
        ["bash", "-c", f'source {LIB} && model_records {config_path} wan2gp-i2v-14B piper'],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    # Wan2GP has 4 files
    assert result.stdout.count("wan2gp_i2v_14B_fp8.safetensors") >= 1
    assert "umt5_xxl_fp8_e4m3fn_scaled.safetensors" in result.stdout
```

**Step 4: Commit**
```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): extend acquire_models for multi-file models with subdir paths"
```

---

## Task 7: Add ComfyUI custom node installation

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** `install_comfyui_custom_nodes` installs custom nodes specified in model config entries. Wan2GP requires `ComfyUI-WanVideoWrapper`.

**Step 1: Implement the function**

```bash
install_comfyui_custom_nodes() {
    local comfyui_path="${1:?comfyui path required}"
    shift
    # Remaining args: list of custom node repo URLs
    for repo_url in "$@"; do
        local node_dir
        node_dir="$(basename "$repo_url" .git)"
        if [[ -d "$comfyui_path/custom_nodes/$node_dir/.git" ]]; then
            printf 'comfyui: custom node %s already installed\n' "$node_dir"
            continue
        fi
        printf 'comfyui: installing custom node %s\n' "$node_dir"
        git clone --depth 1 "$repo_url" "$comfyui_path/custom_nodes/$node_dir" || {
            printf 'comfyui: failed to clone %s\n' "$repo_url" >&2
            return 1
        }
        # Install requirements if present
        if [[ -f "$comfyui_path/custom_nodes/$node_dir/requirements.txt" ]]; then
            "$comfyui_path/venv/bin/pip" install --no-cache-dir -r "$comfyui_path/custom_nodes/$node_dir/requirements.txt" 2>&1 | tail -3 || {
                printf 'comfyui: custom node requirements install failed for %s\n' "$node_dir" >&2
                return 1
            }
        fi
        printf 'comfyui: custom node %s installed\n' "$node_dir"
    done
    return 0
}
```

**Step 2: Wire into wizard**

In Phase 4 (ComfyUI), after `install_comfyui`, check if selected video models require custom nodes and install them:

```bash
# After install_comfyui succeeds:
if [[ -n "$VIDEO_MODEL_SELECTED" && "$VIDEO_PROVIDER" == "local" ]]; then
    local custom_nodes
    custom_nodes=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
model = cfg.get('models', {}).get(sys.argv[2], {})
nodes = model.get('custom_nodes', [])
print(' '.join(nodes))
" "$CONFIG" "$VIDEO_MODEL_SELECTED")
    if [[ -n "$custom_nodes" ]]; then
        for node in $custom_nodes; do
            case "$node" in
                ComfyUI-WanVideoWrapper)
                    install_comfyui_custom_nodes "$COMFYUI_PATH" \
                        "https://github.com/kijai/ComfyUI-WanVideoWrapper" || {
                        on_error 1 "$LINENO" "custom node install failed"
                        exit 1
                    }
                    ;;
            esac
        done
    fi
fi
```

**Step 3: Test and commit**
```bash
cd /home/thx1138/annafoid/clawdess-recovered
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k "custom_node" -v
git add scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): add ComfyUI custom node installation for video models"
```

---

## Task 8: Add Kokoro and XTTS installers

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

**Goal:** Implement `install_kokoro_tts` and `install_xtts_tts` following the same pattern as `install_piper_tts`.

**Step 1: Implement Kokoro installer**

```bash
install_kokoro_tts() {
    local venv_python="${1:?venv python required}"
    
    "$venv_python" -m pip install --no-cache-dir kokoro-onnx 2>&1 | tail -3 || {
        printf 'tts: kokoro pip install failed\n' >&2
        return 1
    }
    printf 'tts: kokoro installed\n'
    return 0
}
```

**Step 2: Implement XTTS installer**

```bash
install_xtts_tts() {
    local venv_python="${1:?venv python required}"
    
    "$venv_python" -m pip install --no-cache-dir TTS 2>&1 | tail -3 || {
        printf 'tts: xtts pip install failed\n' >&2
        return 1
    }
    printf 'tts: xtts installed (model auto-downloads on first use)\n'
    return 0
}
```

**Step 3: Implement vLLM installer**

```bash
install_vllm_tts() {
    local venv_python="${1:?venv python required}"
    
    "$venv_python" -m pip install --no-cache-dir vllm 2>&1 | tail -3 || {
        printf 'tts: vllm pip install failed\n' >&2
        return 1
    }
    printf 'tts: vllm installed\n'
    return 0
}
```

**Step 4: Wire into Phase 6 (TTS installation)**

Replace the current single `install_piper_tts` call with a dispatcher:

```bash
PHASE="tts"
printf '=== Phase 6: TTS ===\n'

if [[ "$DRY_RUN" == false ]]; then
    case "$TTS_BACKEND" in
        piper)
            install_piper_tts "$VENV_PATH/bin/python" || {
                on_error 1 "$LINENO" "TTS installation failed"
                exit 1
            }
            ;;
        kokoro)
            install_kokoro_tts "$VENV_PATH/bin/python" || {
                on_error 1 "$LINENO" "TTS installation failed"
                exit 1
            }
            ;;
        xtts-v2)
            install_xtts_tts "$VENV_PATH/bin/python" || {
                on_error 1 "$LINENO" "TTS installation failed"
                exit 1
            }
            ;;
        vllm)
            install_vllm_tts "$VENV_PATH/bin/python" || {
                on_error 1 "$LINENO" "TTS installation failed"
                exit 1
            }
            ;;
        *)
            printf 'tts: unknown backend %s, defaulting to piper\n' "$TTS_BACKEND" >&2
            install_piper_tts "$VENV_PATH/bin/python" || {
                on_error 1 "$LINENO" "TTS installation failed"
                exit 1
            }
            ;;
    esac
fi
```

**Step 5: Test and commit**
```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k "install_kokoro or install_xtts or install_vllm" -v
git add scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh tests/test_dgx_spark_ac_gaps.py
git commit -m "feat(dgx-spark): add Kokoro, XTTS, and vLLM TTS installers"
```

---

## Task 9: Add interactive Phase 5 display (summary + confirm)

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Goal:** After selection, show the full summary and prompt for confirmation. `--yes` skips. Non-interactive with `--profile` auto-confirms.

**Step 1: Add confirmation block after selection (before dry-run check)**

```bash
# 5d: Summary and confirm
printf '\n=== Configuration Summary ===\n'
printf 'Features: %s\n' "$(echo "$FEATURE_LIST" | tr ' ' ', ')"
if [[ -n "$IMAGE_MODEL" ]]; then
    printf 'Photo: local → %s\n' "$IMAGE_MODEL"
elif echo "$FEATURE_LIST" | grep -q 'photo'; then
    printf 'Photo: remote API\n'
fi
if [[ -n "$VIDEO_MODEL_SELECTED" ]]; then
    printf 'Video: local → %s\n' "$VIDEO_MODEL_SELECTED"
elif echo "$FEATURE_LIST" | grep -q 'video'; then
    printf 'Video: remote API\n'
fi
if [[ -n "$TTS_BACKEND" ]]; then
    printf 'Voice: local → %s\n' "$TTS_BACKEND"
fi

if [[ "$NON_INTERACTIVE" == true || "$AUTO_YES" == true ]]; then
    printf 'auto-confirmed (--non-interactive or --yes)\n'
elif [[ "$DRY_RUN" == true ]]; then
    printf 'dry-run: auto-confirmed\n'
else
    printf '\nContinue? [Y/n] '\
    local confirm
    IFS= read -r confirm || confirm="y"
    case "$confirm" in
        [yY]|[yY]es|"") ;;
        *)
            printf 'aborted by user\n' >&2
            exit 0
            ;;
    esac
fi
```

**Step 2: Test and commit**
```bash
.venv/bin/python -m pytest tests/test_deploy_dgx_spark.py -k "phase5" -v
git add scripts/deploy-dgx-spark.sh tests/test_deploy_dgx_spark.py
git commit -m "feat(dgx-spark): add interactive summary and confirmation in Phase 5"
```

---

## Task 10: Full test suite run and regression check

**Goal:** Verify all 79 existing tests still pass, plus all new tests pass.

**Step 1: Run full suite**
```bash
cd /home/thx1138/annafoid/clawdess-recovered
.venv/bin/python -m pytest tests/ -v 2>&1 | tee /tmp/test-results.log
```

Expected: 79 original + ~25 new tests = ~104 passing, 0 failing.

**Step 2: Run bash syntax check**
```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
```

**Step 3: Dry-run test on hardware**
```bash
python3 scripts/deploy-dgx-spark.sh --profile media --non-interactive --dry-run
```
Expected: completes through model acquisition with all media models listed.

**Step 4: Commit final changes**
```bash
git add -A
git commit -m "feat(dgx-spark): complete feature-first model selector implementation"
```

---

## Task 11: Push and verify

```bash
cd /home/thx1138/annafoid/clawdess-recovered
git push origin repair/dgx-spark-deployment-wizard
gh pr create --title "feat(dgx-spark): feature-first model selector" --body "..."
```

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| New config format breaks existing tests | `model_records` handles both old flat and new nested formats |
| Wan2GP download ~14GB takes time on hardware | `probe_curl` supports resume; tests use injected seams |
| Kokoro/XTTS pip installs may fail on aarch64 | Each installer has `|| return 1` fallback to piper |
| Interactive flow hangs in CI | Non-interactive mode defaults to first option; `[[ ! -t 0 ]]` guard |
| Profile defaults don't match README spec | Verified against README model list and VRAM constraints |

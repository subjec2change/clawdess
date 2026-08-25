# Clawdess

clawdess is more than just a girlfriend. It's the perfect digital companion. Experience a playful, genuine connection with daily photos, captivating videos, and late-night voice notes that make you feel truly special.

## Demo
![alt text](img/clawdess-demo.png)

## Features

- **Photo** — AI-edited selfies from a reference image
- **Video** — Image-to-video generation
- **Voice** — Text-to-speech voice messages

All media can be delivered to WhatsApp, Telegram, Discord, Slack, Signal, and MS Teams via [OpenClaw](https://github.com/openclaw/openclaw).

## Installation

Install as an OpenClaw skill:

```bash
git clone https://github.com/xwings/clawdess ~/.openclaw/skills/clawdess
```

### Requirements

- Python 3
- [OpenClaw](https://github.com/openclaw/openclaw) agent

### API Keys

Set your API keys as environment variables:

```bash
export CLAWDESS_PHOTO_API="your-photo-api-key"
export CLAWDESS_VIDEO_API="your-video-api-key"
export CLAWDESS_VOICE_API="your-voice-api-key"
```

Alternatively, pass them per-command with `--api`.

## Usage

```bash
# Generate and send a photo
python3 scripts/clawdess.py photo \
  --prompt "Render this image as make a pic of this person at a cafe, smiling" \
  --image "https://example.com/reference.png" \
  --channel discord --target "CHANNEL_ID"

# Generate and send a video from an image
python3 scripts/clawdess.py video \
  --prompt "smile and wave at the camera" \
  --image "https://example.com/photo.png" \
  --channel telegram --target "@username"

# Generate and send a voice message
python3 scripts/clawdess.py voice \
  --prompt "Hey! How are you doing today?" \
  --channel discord --target "CHANNEL_ID"
```

The `--channel` and `--target` flags are optional — omit them to generate media without sending.

## Providers

| Type | Provider | Model | Default |
|------|----------|-------|---------|
| Photo | FAL | Bytedance Seedream 4.5 | Yes |
| Photo | HUOSHANYUN | Doubao Seedream 4.5 | |
| Photo | XAI | Grok Imagine Image | |
| Video | FAL | Wan v2.2 | Yes |
| Video | XAI | Grok Imagine Video | |
| Voice | ALIYUN | Qwen3-TTS-Flash | Yes |
| Voice | ELEVENLABS | Eleven Multilingual v2 | |
| Voice | ZAI | GLM-TTS | |

List installed providers:

```bash
python3 scripts/clawdess.py providers
```

Select a provider with `--provider`:

```bash
python3 scripts/clawdess.py photo --provider HUOSHANYUN ...
python3 scripts/clawdess.py video --provider XAI ...
python3 scripts/clawdess.py voice --provider ZAI ...
```

### Adding a Provider

Create a `.py` file in the corresponding `scripts/photo/`, `scripts/video/`, or `scripts/voice/` directory with a `generate()` function. It will be discovered automatically.

## Project Structure

```
scripts/
  clawdess.py          # CLI entry point
  common.py            # Shared helpers (API calls, OpenClaw send, polling)
  photo/               # Photo providers
    fal.py
    huoshanyun.py
    xai.py
  video/               # Video providers
    fal.py
    xai.py
  voice/               # Voice providers
    aliyun.py
    elevenlabs.py
    zai.py
```


## DGX Spark clone-to-wizard workflow

The DGX Spark goal is a reproducible, one-command wizard for an NVIDIA GB10 system: clone this branch, choose a feature set interactively (or provide one for automation), review the plan, and install only the capabilities the checkout can truthfully provide. The wizard is the public Bash entry point; no code changes are required to follow this workflow.

### Clone and prerequisites

Use the exact repair branch that contains the wizard:

```bash
git clone --branch repair/dgx-spark-deployment-wizard --single-branch https://github.com/xwings/clawdess.git
cd clawdess
```

Before a real deployment, confirm:

- NVIDIA DGX Spark with GB10, Linux `aarch64`, and compute capability 12.1 (`nvidia-smi` must report it).
- Python 3.11 or newer, Bash, `git`, `curl`, and `tar`; internet access for repositories, pinned packages, and model files.
- At least 8 GB free where the deployment/model roots live; selected models and deferred experiments may need substantially more.
- Docker is not required for the verified `minimal` path. Non-minimal profiles may check or scaffold Docker-related services.
- Credentials required by any selected remote provider, if applicable. The wizard does not manufacture credentials.

### Interactive and non-interactive commands

Run the wizard with no profile for the interactive path. It asks for features, provider, image/video model entries, and voice backend, prints a selection summary, then asks for confirmation before a real install mutates the deployment. Answer `n` to abort.

```bash
bash scripts/deploy-dgx-spark.sh
```

For automation, `--non-interactive` requires `--profile`; `--yes` confirms the real install. Explicit CLI selections override profile defaults:

```bash
# Preview the selected plan; this is the recommended first command.
bash scripts/deploy-dgx-spark.sh \
  --profile minimal --features photo,voice --provider local \
  --image-model juggernaut-xl-v10 --tts-backend piper \
  --dry-run --non-interactive

# Install the verified local minimal stack after reviewing the dry run.
bash scripts/deploy-dgx-spark.sh \
  --profile minimal --features photo,voice --provider local \
  --image-model juggernaut-xl-v10 --tts-backend piper \
  --non-interactive --yes
```

The complete CLI contract is available without changing anything:

```bash
bash scripts/deploy-dgx-spark.sh --help
```

`--dry-run` performs host/configuration and capability planning, writes inspectable planned state/log evidence, and does not download models, create the virtualenv, start services, or claim a generated artifact. It is safe to use for deferred selections. A non-dry-run selection of a deferred, unavailable, or blocked capability exits non-zero rather than silently pretending to install it.

### Feature/capability truth table

| Feature or backend | Current state | What the wizard can truthfully do | Evidence boundary |
|---|---|---|---|
| Photo / ComfyUI, local | `verified` for the minimal path | Acquire the catalog image model, start ComfyUI, and run the photo smoke test when host prerequisites pass | A successful deployment/smoke test is required; selection or dry-run is not runtime evidence |
| Piper voice (`piper`/`piper-voice`) | `verified` | Acquire the catalog voice files, install Piper, and run the voice smoke test | This proves the configured Piper path only, not voice quality parity or other TTS backends |
| Video / Wan2GP local | `deferred` | Record/preflight the selected catalog model and dependency paths; dry-run may show the plan | No native video service, health check, download, or generated video is claimed by this wizard today |
| Kokoro | `experimental` | Record the catalog/backend seam for planning; not a verified installer capability | No successful Kokoro installation or audio artifact should be inferred |
| XTTS-v2 | `deferred` | Record the backend seam and required speaker-WAV placeholder | No XTTS runtime or artifact is provided |
| Local LLM / vLLM | `deferred` | Keep it in capability planning where a profile mentions it | The wizard is not a local LLM installer |
| Remote provider | `planning/delegation` | Record provider selection and skip local acquisition where supported | Remote selection does not prove a remote call, local video runtime, or local voice dependencies |

Profiles are bundles, not proof of capability: `minimal` targets photo + Piper; `media` and `assistant` include experimental/deferred planning; `all` includes all cataloged selections and is not recommended for unattended deployment. The machine-readable state/manifest records states such as `verified`, `experimental`, `deferred`, `unavailable`, and `blocked` separately from provider selection.

### Logs, state, and lifecycle commands

The default deployment root is `$HOME/.local/share/clawdess-dgx-spark`; set `CLAWDESS_DEPLOY_ROOT` or pass `--deploy-root` to change it. The model root defaults to `$DEPLOY_ROOT/models`; set `CLAWDESS_MODEL_ROOT` or pass `--model-root` to override it. A deployment root contains:

- `logs/` — timestamped deployment output plus service logs such as `comfyui.log` and `tts.log`.
- `state/` — `deployment-state.json` and capability/selection state, including `planned`, `running`, `partial`, `failed`, or `completed` transitions.
- `models/` — downloaded model files (or the separately selected model root).
- `run/` — service PID/runtime files; `venv/` — the deployment virtual environment.
- `bin/status` and `bin/health-check` — lifecycle/status checks generated after deployment; `deployment-manifest.json` — final recorded result.

Inspect the result with:

```bash
$DEPLOY_ROOT/bin/status
$DEPLOY_ROOT/bin/health-check
```

Treat `planned`/dry-run state as planning evidence only. For video specifically, the repository's video preflight distinguishes `preflight`, `health`, and `artifact` evidence: only a real health response can support `health`, and only recorded completed state plus a non-empty video file can support `artifact`. Piper evidence is likewise limited to the actual Piper smoke test; a catalog entry, dry run, or manifest selection is not proof of working TTS.

### Expected limitations

- The documented verified path is local photo + Piper voice on the GB10. Video, Kokoro, XTTS-v2, and local LLM/vLLM remain deferred or experimental seams.
- Model downloads, package installation, GPU/runtime compatibility, storage, and third-party availability can still fail on the target host; inspect the logs and state rather than treating a plan as success.
- Remote provider selection changes planning/acquisition behavior but does not install or validate remote services.
- No claim is made here that Piper sounds like another TTS system, that a video model generated a usable clip, or that a future/non-minimal profile is production-ready.

## License

See [LICENSE](LICENSE).

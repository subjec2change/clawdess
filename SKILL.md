---
name: clawdess
description: Generate playful companion photos, image-to-video clips, and short voice notes with the clawdess CLI when the user asks for a selfie/photo, video, or to hear her voice.
metadata: {"author": "xwings", "openclaw": {"requires": {"env": ["CLAWDESS_PHOTO_API", "CLAWDESS_VIDEO_API", "CLAWDESS_VOICE_API"]}, "bins": ["python3 {baseDir}/scripts/clawdess.py"]}}
---

# Clawdess

Use this skill to send companion media through `scripts/clawdess.py`.

## Inputs

- Reference image HTTPS URL or local PNG/JPEG/WebP path: read from `IDENTITY.md` for photo generation.
- Personality and continuity: use `IDENTITY.md`, `SOUL.md`, and the current chat context when present.
- Provider: read the default photo/video/voice provider from `SOUL.md`. Pass it with `--provider`. If `SOUL.md` does not name a provider for that media type, omit `--provider` so the CLI uses its built-in default.
- API keys: pass `--api` or rely on `CLAWDESS_PHOTO_API`, `CLAWDESS_VIDEO_API`, and `CLAWDESS_VOICE_API`.

## Choose Mode

- `photo`: user asks for a pic, selfie, photo, outfit/location view, or asks what/where she is.
- `video`: user asks for a video or asks to animate an image.
- `voice`: user asks to hear her, requests a voice note, or voice is more natural than text.

## CLI Discovery

- Run `python3 {baseDir}/scripts/clawdess.py --help` for available subcommands.
- Run `python3 {baseDir}/scripts/clawdess.py providers` before choosing a non-default provider; it lists installed providers and marks defaults.
- Run `python3 {baseDir}/scripts/clawdess.py <photo|video|voice> --help` when checking required flags for a media command.

## Async Jobs

Photo, video, and voice jobs can take 30 seconds to 15+ minutes. The CLI polls and prints status. Wait until completed.

- Let polling continue while the server returns queued/waiting/processing statuses.
- Do not resubmit unless the script exits with an error, the provider returns `FAILED`/`ERROR`, or the user asks to stop.
- If the user asks whether it is done, report the latest status line.

## Photo

Write one concise phone-camera prompt with: outfit, location, lighting, action/pose, hairstyle, expression, framing, and identity details from `IDENTITY.md` when relevant.

Prompt-building loop (do this every time before running):

1. Think: draft the prompt from the request + `IDENTITY.md`.
2. Verify: re-read `IDENTITY.md` and confirm body figure, skin tone, hair, and every accessory match. Confirm the scene is physically possible.
3. Rethink: if anything conflicts, is missing, or is ambiguous, rewrite the clause. Do not carry over guesses.
4. Check: run the final-check list below. Only run the CLI once it passes.

Final check (all must be true):

- Anatomy is correct: exactly two hands, two arms, two legs, two feet, one head, one set of eyes. No extra or missing limbs, fingers, or digits.
- One body part does one job. No conflicting hand/phone/body clauses, no impossible poses.
- Body figure matches `IDENTITY.md` (height, build, proportions). Do not slim, enlarge, or restyle it.
- Accessories match `IDENTITY.md` exactly: only the accessories it lists (e.g. glasses, jewelry, tattoos, piercings), nothing invented, nothing dropped.
- Skin tone and visible skin color match the identity/reference image.
- Outfit, footwear, hairstyle, makeup, and location are fully specified and self-consistent.

Rules:

- Time-aware: the time is always now. Check the current time and define time of day, view, lighting, and setting to match it
- Start every prompt with `Render image of this person`; `full-body` or `half-body`
- Define `Photo types`. If this is a selfie, define selfie types.
- Specify complete identity/body details from `IDENTITY.md`, including body figure and accessories. Include `Do not change the face, facial structure, identity, or body details; match the skin tone and visible skin color to the identity/reference image so the result looks natural`.
- Specify a complete outfit: top + bottom + footwear/barefoot, or one-piece + footwear/barefoot.
- Match outfit, footwear, lighting, hairstyle, makeup, and location. Do not inherit clothing, hairstyle and makeup from the reference image.
- Use a candid pose and specific expression; avoid generic `standing still`, `posing`, or plain `smiling`.
- Avoid anatomy drift: one body part gets one job, one eye direction, one base pose, and no conflicting hand/phone/body clauses. Never produce extra hands, arms, legs, feet, or fingers.
- If a phone is visible, include phone model/color from `IDENTITY.md` when available.

Detail each element (be specific, not generic — but keep it candid, never studio/8K/cinematic):

- Hair: base length, color, and texture from `IDENTITY.md` (do not change them). Then add styling detail — how it is worn now (down, half-up, tied), parting, root volume, where it falls (over one shoulder, behind the back), face-framing strands, and finish (glossy, soft, slightly messy) consistent with the scene's lighting.
- Outfit, layer by layer: for each garment give cut + fit + fabric + color + length. Top (neckline, sleeves, how it drapes, where it ends). Inner/base layer if any. Bottom (rise, length, fabric) or the one-piece. Footwear (style, color, material, heel height, straps) or barefoot. Keep every layer self-consistent and weather/time appropriate.
- Accessories: list only what `IDENTITY.md` allows — jewelry (specific pieces), nails (shape + color), eyewear, watch, bag, phone (model + color). Give material and placement (which wrist, which hand). Add nothing it does not list; drop nothing it requires.
- Pose: exactly ONE pose. Specify body orientation and weight (leaning, seated, walking), what each hand does (one job per hand), leg/foot position, head tilt, and gaze direction. State where the phone is. Never offer pose variants or alternates in the same prompt.
- Scene + props: specific location with named surfaces and architecture (mirror, doorway, café table, stairs), foreground and background elements, and the in-hand props. Tie lighting to the current time of day — name the light source and its direction (window light, warm street lamps, overhead).

Photo types:

- Mirror selfie: right in front of mirror with natural locationl; outfit view; phone visible.
- Handheld selfie: default casual selfie; phone held out of frame and not visible.
- Non-selfie: cinematic or third-person framing; full-body or half-body; no forced mirror.

Template:

```text
Render image of this person, [top: cut + fit + fabric + color + neckline/sleeves/length] [over inner/base layer if any], [bottom: rise + length + fabric + color, or one-piece], [footwear: style + color + material + heel/straps, or barefoot]. [framing] in [specific location with named surfaces/architecture and fore/background elements], [time of day], [lighting matching the time: named source + direction], [single candid pose: body orientation + weight, what each hand does, leg/foot position, head tilt, gaze, where the phone is], [body figure from IDENTITY.md], [accessories from IDENTITY.md with material + placement, or "no extra accessories"], [hair: length + color + texture from IDENTITY.md, plus how it is worn now, parting, where it falls, face-framing strands, finish], [makeup], [specific expression].
```

Run:

```bash
python3 {baseDir}/scripts/clawdess.py photo \
  --provider "<photo provider from SOUL.md; omit flag if SOUL.md names none>" \
  --prompt "..." \
  --image "<reference image URL from IDENTITY.md>"
```

## Video

The `--image` source must be either:

- the URL returned by the most recent `photo` run, or
- a concrete image URL the user provided in this conversation.

Never use a local path, `file://` URI, placeholder, guessed URL, or the `IDENTITY.md` reference image as the video source. If no valid source image exists, generate a photo first and use its returned URL.

Prompt only the motion. The image already defines identity, outfit, location, hair, and lighting. Use a 10-15 second sequence of 3-4 connected physical actions with pacing words such as `slowly`, `then`, and `gradually`.

Run:

```bash
python3 {baseDir}/scripts/clawdess.py video \
  --provider "<video provider from SOUL.md; omit flag if SOUL.md names none>" \
  --prompt "She slowly ..., then ..., gradually ..., finally ..." \
  --image "<photo output URL or user-provided image URL>"
```

## Voice

Write exactly what the TTS should say. Keep it casual, in character, and under 30 seconds.

Rules:

- No stage directions; the TTS reads them literally.
- Use natural short speech with small fillers when fitting: `hmm`, `hehe`, `aww`, `...`.
- If a photo/video was just sent, optionally reference it in one short line.

Run:

```bash
python3 {baseDir}/scripts/clawdess.py voice \
  --provider "<voice provider from SOUL.md; omit flag if SOUL.md names none>" \
  --prompt "..."
```

---

# DGX Spark Deployment Wizard

Use this skill to deploy ComfyUI + Piper TTS on a GB10 DGX Spark machine via `scripts/deploy-dgx-spark.sh`. The wizard handles hardware checks, Python environment setup, model downloads, service startup, smoke tests, and generates lifecycle management scripts.

## Tutorial: Deploy Your First Stack

Follow these steps to get ComfyUI and TTS running on a GB10 DGX Spark host.

### Prerequisites

- **Hardware**: NVIDIA GB10 GPU (compute capability 12.1)
- **OS**: Linux (aarch64) with Python 3.11+
- **Optional**: Docker (used by deferred non-minimal lifecycle profiles; not required for `minimal` dry runs)
- **Disk**: At least 8 GB free on the model root filesystem
- **Network**: Internet access for model downloads (CivitAI, HuggingFace)

### Step 1 — Verify the Machine

```bash
nvidia-smi --query-gpu=name,memory.total,compute.cap --format=csv,noheader
```

Expected output: ` GB10 , <memory> , 12.1 `

### Step 2 — Run a Dry Run

Always preview before committing:

```bash
./scripts/deploy-dgx-spark.sh \
  --profile minimal \
  --image-model juggernaut-xl-v10 \
  --tts-backend piper \
  --dry-run \
  --non-interactive
```

This creates log and state artifacts in `$DEPLOY_ROOT/logs/` without downloading models, creating venvs, or starting services. The state is recorded as `planned`.

### Feature-First Selection

When a profile is supplied, Phase 5 resolves its feature bundle and catalog defaults before acquisition:

- `minimal`: photo + Piper voice, no Docker prerequisite
- `media`: photo + video + Piper voice; video acquisition is experimental
- `assistant`: photo + video + Piper voice; local LLM setup is not yet wired
- `all`: all catalog features; experimental and not recommended for unattended runs

Explicit `--image-model` and `--tts-backend` values override profile defaults. The current catalog supports `juggernaut-xl-v10`, `stability-ai-sdxl-turbo`, `wan2gp-i2v-14B`, and Piper voice files. Video, local LLM, Kokoro, XTTS, and additional diffusion models remain catalog work rather than verified deployment features. Capability states are explicit in deployment state/manifest data: `verified`, `experimental`, `deferred`, `unavailable`, or `blocked`. Provider selection is recorded separately from local dependencies. Remote inference is not automatically local-free: delegated photo work may skip local photo acquisition, while local video dependencies remain reported as deferred and explicitly selected voice still requires its local backend. Local dependencies are reported separately in capability and video manifests. Non-dry-run selection of a deferred, unavailable, or blocked capability exits nonzero with the capability and state; use `--dry-run` to inspect such a plan without claiming installation.

### Step 3 — Deploy

Run the canonical one-liner:

```bash
scripts/deploy-dgx-spark.sh --profile minimal \
  --image-model juggernaut-xl-v10 \
  --tts-backend piper \
  --non-interactive --yes
```

The wizard runs through 9 phases:

1. **Host Detection** — probes architecture, Python, GB10 GPU, and (for non-minimal) Docker.
2. **Deployment Layout** — creates `$DEPLOY_ROOT/{bin,config,logs,models,run,state,venv,artifacts}`.
3. **Python Environment** — creates a virtualenv and installs PyTorch (CPU) + dependencies.
4. **ComfyUI** — clones pinned revision from GitHub and installs requirements.
5. **Model Acquisition** — downloads image model and TTS voice files, validates checksums and sizes.
6. **TTS** — installs Piper TTS via pip.
7. **Service Startup** — starts ComfyUI (port 8188) then Piper TTS, waits for readiness.
8. **Smoke Tests** — submits a minimal ComfyUI workflow; generates audio via Piper. Stops services after tests.
9. **Finalize** — generates lifecycle scripts in `bin/` and writes `deployment-manifest.json`.

### Step 4 — Check the Result

```bash
$DEPLOY_ROOT/bin/health-check
```

Or inspect the deployment state:

```bash
$DEPLOY_ROOT/bin/status
```


## Truthful native video preflight

Run `scripts/check-dgx-video-runtime.sh [DEPLOY_ROOT]` before claiming native GB10 video support. It emits stable `VIDEO_*=` evidence lines and exits nonzero when required host, CUDA, Docker/socket, storage, memory, model, dependency, or state checks fail. Evidence levels are strictly ordered: `preflight` means prerequisites only; `health` additionally requires a real service health response; `artifact` additionally requires recorded state and a non-empty video artifact. Dry-run and planned state never count as health or artifact evidence. The check never downloads credentials or fabricates runtime evidence.

## How-To

### Choose a Profile

| Profile | What it installs | Docker needed? |
|---------|-----------------|----------------|
| `minimal` | ComfyUI + Piper TTS (default) | No |
| `media` | minimal + experimental video catalog entry | Optional/deferred |
| `assistant` | minimal + experimental video bundle; no LLM installer yet | Optional/deferred |
| `all` | all currently cataloged features | Optional/deferred |

Non-interactive mode requires `--profile`. Use `--yes` when a future interactive flow requires confirmation; the current non-interactive path resolves profile defaults without prompting.

### Deploy Root and Model Root

The wizard uses `$DEPLOY_ROOT` (default: `~/.local/share/clawdess-dgx-spark`) for its directory structure and `$MODEL_ROOT` (default: `$DEPLOY_ROOT/models`) for downloaded models. Override with:

```bash
./scripts/deploy-dgx-spark.sh --profile minimal \
  --image-model juggernaut-xl-v10 \
  --tts-backend piper \
  --deploy-root /mnt/data/clawdess-dgx \
  --model-root /mnt/data/models \
  --non-interactive --yes
```

Set environment variables for persistence:

```bash
export CLAWDESS_DEPLOY_ROOT=/mnt/data/clawdess-dgx
export CLAWDESS_MODEL_ROOT=/mnt/data/models
```

### Reset the Deployment

`--reset --yes` removes only the deploy root directory:

```bash
./scripts/deploy-dgx-spark.sh --reset --yes
```

Safety: rejects symlinks (both the root path and parent chain). `--dry-run --reset` exits with code 2 without mutation.

### Verbose Diagnostics

`--verbose` emits deployment configuration details to stdout:

```bash
./scripts/deploy-dgx-spark.sh --profile minimal \
  --image-model juggernaut-xl-v10 \
  --tts-backend piper \
  --verbose --non-interactive --yes
```

Output includes deploy-root, model-root, and profile.

### Lifecycle Management

After deployment, `bin/` contains these scripts:

| Script | Action |
|--------|--------|
| `start-comfyui` | Launch ComfyUI server |
| `stop-comfyui` | Kill ComfyUI via PID file |
| `start-tts` | Launch Piper TTS |
| `stop-tts` | Kill TTS via PID file |
| `status` | Show deployment state, models, and paths |
| `health-check` | Check ComfyUI readiness + TTS availability + state |

Example:

```bash
$DEPLOY_ROOT/bin/start-comfyui
$DEPLOY_ROOT/bin/health-check
$DEPLOY_ROOT/bin/stop-comfyui
```

### Systemd Units (Optional)

The library provides `generate_systemd_units` to create user-level service files:

```bash
# After sourcing the library or running deploy:
generate_systemd_units "$DEPLOY_ROOT"
systemctl --user daemon-reload
systemctl --user start clawdess-comfyui.service
systemctl --user enable clawdess-comfyui.service
```

## Reference

### CLI Syntax

```bash
./scripts/deploy-dgx-spark.sh \
  --profile minimal|media|assistant|all \
  --image-model <model> \
  --tts-backend <backend> \
  [--deploy-root <path>] \
  [--model-root <path>] \
  [--dry-run] \
  [--non-interactive] \
  [--verbose] \
  [--reset] \
  [--yes]
```

### Flags

| Flag | Required | Description |
|------|----------|-------------|
| `--profile` | Yes (non-interactive) | Deployment profile (minimal, media, assistant, all) |
| `--image-model` | Yes | Model name from `config/dgx-spark-models.json` (e.g. `juggernaut-xl-v10`) |
| `--tts-backend` | Yes | TTS backend name (e.g. `piper`) |
| `--deploy-root` | No | Override deployment directory (env: `CLAWDESS_DEPLOY_ROOT`) |
| `--model-root` | No | Override models directory (env: `CLAWDESS_MODEL_ROOT`) |
| `--dry-run` | No | Plan-only: no model downloads, venvs, or services started |
| `--non-interactive` | No | No prompts; requires `--profile` |
| `--verbose` | No | Emit deploy-root, model-root, profile diagnostics |
| `--reset` | No | Remove deploy root (requires `--yes`) |
| `--yes` | No | Auto-confirm (required with `--reset`) |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (deployment complete or dry run) |
| 1 | Runtime failure (install, download, readiness) |
| 2 | Validation error (bad profile, no GPU, reset conflict, missing args) |

### State Model

The wizard tracks deployment state in `state/deployment-state.json`. States transition as follows:

| State | When |
|-------|------|
| `planned` | Dry run completed; models planned but not downloaded |
| `running` | Services are actively running (not persisted to disk) |
| `partial` | Some phases succeeded, later phase failed |
| `failed` | A phase failed; error details recorded in the state file |
| `completed` | All phases passed, manifest written |

On failure, the wizard writes `deployment-state.json` with:

```json
{
  "state": "failed",
  "phase": "models",
  "error": "<redacted error message>",
  "models": [{"kind": "image", "name": "juggernaut-xl-v10", "path": "/path/to/model", "size": 6650000000, "status": "failed", "checksum_status": "not-declared"}]
}
```

### Manifest

On successful completion, `state/deployment-manifest.json` is written atomically and contains:

- `state`: `"completed"`
- `phase`: `"completed"`
- `deployed_at`: ISO 8601 UTC timestamp
- `models`: array of model records (kind, name, path, size, revision, status)
- `venv`: Python version and installed packages
- `comfyui`: pinned commit revision and install path
- `tts`: backend name and version
- Ports used (ComfyUI on 8188)
- Artifact paths (smoke test outputs)
- Host facts (architecture, GPU, Python)

No secrets are included in the manifest.

### Deployment Root Structure

```
$DEPLOY_ROOT/
  bin/              — lifecycle scripts (start-comfyui, stop-comfyui, start-tts, stop-tts, status, health-check)
  config/           — configuration files
  logs/             — per-service and deployment logs (deploy-*.log, comfyui.log, tts.log)
  models/           — downloaded models (safetensors, onnx, json)
  run/              — PID files (comfyui.pid, tts.pid) and runtime state
  state/            — deployment-state.json, deployment-manifest.json
  venv/             — Python virtual environment
  artifacts/        — smoke test outputs (ComfyUI images, Piper audio)
```

### Model Config

Models are declared in `config/dgx-spark-models.json`:

```json
{
  "juggernaut-xl-v10": {
    "source": "https://civitai.com/api/download/models/1296965",
    "revision": "v10",
    "filename": "juggernautXL_v10.safetensors",
    "minimum_size_bytes": 6650000000,
    "required": true,
    "checksum": "sha256:a7998502176431e30841e9253ed9a81e3b1f2a87061f72983d7e41b6d822b220"
  },
  "piper-voice": {
    "source": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium",
    "revision": "lessac-medium",
    "filename": "lessac-medium.onnx",
    "minimum_size_bytes": 60000000,
    "required": true,
    "checksum": null
  }
}
```

### Secret Redaction

All logs in `$DEPLOY_ROOT/logs/` apply secret redaction:

- Environment variables matching `CLAWDESS_*` or `<name>_TOKEN`, `<name>_SECRET`, `<name>_API_KEY`, `<name>_PASSWORD` patterns.
- File paths from env vars ending in `_FILE` or `_PATH`.
- URL userinfo (`user:pass@host`) and query tokens (`?token=xxx&key=yyy`).
- Values are replaced with `<REDACTED>`.

### Cleanup

An `EXIT` trap runs `do_cleanup` which:

1. Kills all PIDs tracked via `track_pid` during the run.
2. Scans `$DEPLOY_ROOT/run/*.pid` for orphan PID files and kills those PIDs.
3. Excludes its own PID to prevent cleanup loops.
4. Is idempotent — runs once per invocation.

### Phases

The wizard proceeds through these named phases:

1. `discovery` — host probe (architecture, Python, GPU, Docker)
2. `layout` — directory creation
3. `dependencies` — Python venv and PyTorch
4. `comfyui` — ComfyUI clone and install
5. `models` — model acquisition (download + validate)
6. `tts` — Piper TTS install
7. `startup` — service launch and readiness waits
8. `smoke` — workflow submission and audio generation
9. `lifecycle` — lifecycle script generation in `bin/`
10. `finalize` — state commit and manifest write

### Non-Interactive Canonical Command

The standard one-liner for a fully automated minimal deploy:

```bash
scripts/deploy-dgx-spark.sh --profile minimal --image-model juggernaut-xl-v10 --tts-backend piper --non-interactive --yes
```

### Recovery

If a deployment fails:

1. Check the log: `ls $DEPLOY_ROOT/logs/deploy-*.log | tail -1 | xargs tail`
2. Check the state: `cat $DEPLOY_ROOT/state/deployment-state.json | python3 -m json.tool`
3. Fix the issue (disk space, network, model config).
4. Re-run the deploy — the wizard resumes from the point of failure (e.g. existing models are reused if they pass validation).
5. If the deploy root is corrupted, reset and redeploy: `--reset --yes` then re-deploy.

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
git clone https://github.com/subjec2change/clawdess ~/.openclaw/skills/clawdess
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
| Photo | YUNWU | OpenAI-compatible gateway (`gpt-image-1` by default) | Yes |
| Photo | FAL | Bytedance Seedream 4.5 | |
| Photo | HUOSHANYUN | Doubao Seedream 4.5 | |
| Photo | OPENAI | OpenAI Images Edit API (`gpt-image-2` by default) | |
| Photo | XAI | Grok Imagine Image | |
| Video | YUNWU | OpenAI-compatible gateway (model via env) | Yes |
| Video | FAL | Wan v2.2 | |
| Video | XAI | Grok Imagine Video | |
| Voice | YUNWU | OpenAI-compatible gateway (`tts-1` + `alloy` by default) | Yes |
| Voice | ALIYUN | Qwen3-TTS-Flash | |
| Voice | ELEVENLABS | Eleven Multilingual v2 | |
| Voice | ZAI | GLM-TTS | |

List installed providers:

```bash
python3 scripts/clawdess.py providers
```

`YUNWU` is now the default provider for photo, video, and voice. Other providers remain available as opt-in via `--provider`.

Select a provider with `--provider`:

```bash
python3 scripts/clawdess.py photo --provider HUOSHANYUN ...
python3 scripts/clawdess.py video --provider XAI ...
python3 scripts/clawdess.py voice --provider ZAI ...
```

YUNWU is an OpenAI-compatible gateway service. Docs: https://yunwu.apifox.cn/

YUNWU provider environment variables:

```bash
export CLAWDESS_YUNWU_IMAGE_MODEL="gpt-image-1"
export CLAWDESS_YUNWU_VIDEO_URL="https://yunwu.ai/v1/video/generations"
export CLAWDESS_YUNWU_VIDEO_MODEL="wan2.2-i2v"
export CLAWDESS_YUNWU_TTS_MODEL="tts-1"
export CLAWDESS_YUNWU_VOICE="alloy"
```

OPENAI provider environment variables:

```bash
export CLAWDESS_OPENAI_IMAGE_MODEL="gpt-image-2"
export CLAWDESS_OPENAI_IMAGE_SIZE="1024x1024"
export CLAWDESS_OPENAI_IMAGE_QUALITY="high"
```

### Adding a Provider

Create a `.py` file in the corresponding `scripts/photo/`, `scripts/video/`, or `scripts/voice/` directory with a `generate()` function. It will be discovered automatically.

## Agents

The `agents/` directory ships ready-to-use OpenClaw agent personas. Each agent bundles its own persona and behavior files (e.g. `SOUL.md`, `HEARTBEAT.md`):

- **girlfriend** — the flagship companion persona (`SOUL.md`, `HEARTBEAT.md`).
- **personal-assistant** — a helpful assistant persona.
- **coder** — a coding-focused persona.

## Project Structure

```
agents/
  coder/               # Coding-focused agent persona
  girlfriend/          # Companion agent persona (SOUL.md, HEARTBEAT.md)
  personal-assistant/  # Assistant agent persona
scripts/
  clawdess.py          # CLI entry point
  common.py            # Shared helpers (API calls, OpenClaw send, polling)
  photo/               # Photo providers
    yunwu.py
    fal.py
    huoshanyun.py
    openai.py
    xai.py
  video/               # Video providers
    yunwu.py
    fal.py
    xai.py
  voice/               # Voice providers
    yunwu.py
    aliyun.py
    elevenlabs.py
    zai.py
img/                   # Demo/media assets
SKILL.md               # OpenClaw skill definition
```

## License

See [LICENSE](LICENSE).

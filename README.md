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

## License

See [LICENSE](LICENSE).

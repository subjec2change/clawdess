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
| Photo | OPENAI | GPT Image 2 | |
| Photo | XAI | Grok Imagine Image | |
| Photo | YUNWU | gpt-image-1 (configurable) | |
| Video | FAL | Wan v2.2 | Yes |
| Video | XAI | Grok Imagine Video | |
| Video | YUNWU | wan2.1-i2v-14b-720p (configurable) | |
| Voice | ALIYUN | Qwen3-TTS-Flash | Yes |
| Voice | ELEVENLABS | Eleven Multilingual v2 | |
| Voice | ZAI | GLM-TTS | |
| Voice | YUNWU | tts-1 / alloy (configurable) | |

List installed providers:

```bash
python3 scripts/clawdess.py providers
```

Select a provider with `--provider`:

```bash
python3 scripts/clawdess.py photo --provider HUOSHANYUN ...
python3 scripts/clawdess.py video --provider XAI ...
python3 scripts/clawdess.py voice --provider ZAI ...
python3 scripts/clawdess.py photo --provider YUNWU ...
python3 scripts/clawdess.py video --provider YUNWU ...
python3 scripts/clawdess.py voice --provider YUNWU ...
```

### YUNWU Provider

[yunwu.ai](https://yunwu.ai) is an OpenAI-compatible API gateway that proxies
200+ models (OpenAI, Anthropic, Google Gemini, Seedream, and more) behind a
single API key. See the [yunwu.ai API docs](https://yunwu.apifox.cn/) for
available models and endpoints.

Use your yunwu.ai token as the API key (e.g. `CLAWDESS_PHOTO_API`).

Configurable environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAWDESS_YUNWU_IMAGE_MODEL` | `gpt-image-1` | Image model for photo generation |
| `CLAWDESS_YUNWU_IMAGE_SIZE` | `1024x1024` | Image output size |
| `CLAWDESS_YUNWU_IMAGE_QUALITY` | `high` | Image output quality |
| `CLAWDESS_YUNWU_VIDEO_URL` | `https://yunwu.ai/v1/video/generations` | Video generation endpoint |
| `CLAWDESS_YUNWU_VIDEO_MODEL` | `wan2.1-i2v-14b-720p` | Video model |
| `CLAWDESS_YUNWU_TTS_MODEL` | `tts-1` | TTS model for voice generation |
| `CLAWDESS_YUNWU_VOICE` | `alloy` | Voice name for TTS |

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

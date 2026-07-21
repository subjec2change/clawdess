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

The default provider for all media types is **YUNWU** ([yunwu.ai](https://yunwu.ai) — an OpenAI-compatible gateway). Set a single API key for all three media types:

```bash
export CLAWDESS_PHOTO_API="your-yunwu-api-key"
export CLAWDESS_VIDEO_API="your-yunwu-api-key"
export CLAWDESS_VOICE_API="your-yunwu-api-key"
```

Alternatively, pass them per-command with `--api`. To use a different provider, pass `--provider` (see [Providers](#providers) below).

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
| Photo | YUNWU | GPT Image 1 (via yunwu.ai) | Yes |
| Photo | FAL | Bytedance Seedream 4.5 | |
| Photo | HUOSHANYUN | Doubao Seedream 4.5 | |
| Photo | XAI | Grok Imagine Image | |
| Photo | OPENAI | GPT Image 2 | |
| Video | YUNWU | Kling v2 Master (via yunwu.ai) | Yes |
| Video | FAL | Wan v2.2 | |
| Video | XAI | Grok Imagine Video | |
| Voice | YUNWU | TTS-1 (via yunwu.ai) | Yes |
| Voice | ALIYUN | Qwen3-TTS-Flash | |
| Voice | ELEVENLABS | Eleven Multilingual v2 | |
| Voice | ZAI | GLM-TTS | |

List installed providers:

```bash
python3 scripts/clawdess.py providers
```

Select a provider with `--provider` (YUNWU is used when omitted):

```bash
python3 scripts/clawdess.py photo --provider FAL ...
python3 scripts/clawdess.py video --provider XAI ...
python3 scripts/clawdess.py voice --provider ALIYUN ...
```

### Adding a Provider

Create a `.py` file in the corresponding `scripts/photo/`, `scripts/video/`, or `scripts/voice/` directory with a `generate()` function. It will be discovered automatically.

## Project Structure

```
scripts/
  clawdess.py          # CLI entry point
  common.py            # Shared helpers (API calls, OpenClaw send, polling)
  photo/               # Photo providers
    yunwu.py           # (default)
    fal.py
    huoshanyun.py
    openai.py
    xai.py
  video/               # Video providers
    yunwu.py           # (default)
    fal.py
    xai.py
  voice/               # Voice providers
    yunwu.py           # (default)
    aliyun.py
    elevenlabs.py
    zai.py
```

## License

See [LICENSE](LICENSE).

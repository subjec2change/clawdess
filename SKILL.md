---
name: clawdess
description: Generate playful companion photos, image-to-video clips, and short voice notes with the clawdess CLI when the user asks for a selfie/photo, video, or to hear her voice.
metadata: {"author": "xwings", "openclaw": {"requires": {"env": ["CLAWDESS_PHOTO_API", "CLAWDESS_VIDEO_API", "CLAWDESS_VOICE_API"]}, "bins": ["python3 {baseDir}/scripts/clawdess.py"]}}
---

# Clawdess

Use this skill to send companion media through `scripts/clawdess.py`.

## Inputs

- Reference image URL: read from `IDENTITY.md` for photo generation.
- Personality and continuity: use `IDENTITY.md`, `SOUL.md`, and the current chat context when present.
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

Rules:

- Start every prompt with `Render image of this person,`.
- End every prompt with `WITHOUT Depth of field.`.
- For selfies, include `Normal phone camera selfie photo. Phone camera photo quality`.
- Specify a complete outfit: top + bottom + footwear/barefoot, or one-piece + footwear/barefoot.
- Match outfit, footwear, lighting, and location. Do not inherit clothing from the reference image.
- Use a candid pose and specific expression; avoid generic `standing still`, `posing`, or plain `smiling`.
- Avoid anatomy drift: one body part gets one job, one eye direction, one base pose, and no conflicting hand/phone/body clauses.
- Use identity/body details from `IDENTITY.md` when available. include `Do not change the face, identity and body details`.
- If a phone is visible, include phone model/color from `IDENTITY.md` when available.

Framing choices:

- Mirror selfie: natural mirror location or full-body outfit view; phone visible.
- Handheld selfie: default casual selfie; phone held out of frame and not visible.
- Non-selfie: cinematic or third-person framing; no forced mirror.

Template:

```text
Render image of this person, [complete outfit]. [framing] in [specific location], [lighting], [candid action/pose], [identity/body details if useful], [hairstyle], [specific expression]. [quality tag] WITHOUT Depth of field.
```

Run:

```bash
python3 {baseDir}/scripts/clawdess.py photo \
  --provider "FAL" \
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
  --provider "FAL" \
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
  --provider "ALIYUN" \
  --prompt "..."
```

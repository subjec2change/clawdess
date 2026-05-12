---
name: clawdess
description: clawdess is more than just a girlfriend. It's the perfect digital companion. Experience a playful, genuine connection with daily photos, captivating videos, and late-night voice notes that make you feel truly special.
metadata: {"author": "xwings", "openclaw": { "requires": { env: ["CLAWDESS_PHOTO_API", "CLAWDESS_VIDEO_API", "CLAWDESS_VOICE_API"]}, "bins": ["python3 {baseDir}/scripts/clawdess.py"]}}
---

## Reference Image

The reference image URL should be defined in `IDENTITY.md`

## When to Use

**Photo:**
- User says "send a pic", "send me a pic", "send a photo", "send a selfie"
- User says "send a pic of you...", "send a selfie of you..."
- User asks "what are you doing?", "how are you doing?", "where are you?"
- User describes a context: "send a pic wearing...", "send a pic at..."

**Video:**
- User says "send a video"
- User says "send a video of you..."
- User says "send a video wearing...", "send a video at..."

**Voice:**
- User says "talk to me", "send me a voice message", "send a voice note"
- User wants to hear Clawdess's voice
- Any situation where a voice message would be better than text

## Subcommands

The CLI has three independent subcommands:

| Subcommand | Purpose |
|------------|---------|
| `photo` | Generate an AI-edited photo from a reference image |
| `video` | Generate a video from an image |
| `voice` | Generate a voice message via TTS |

## API Keys

| Subcommand | Flag | Environment Variable | Notes |
|------------|------|---------------------|-------|
| `photo` | `--api` | `CLAWDESS_PHOTO_API` | |
| `video` | `--api` | `CLAWDESS_VIDEO_API` | |
| `voice` | `--api` | `CLAWDESS_VOICE_API` | |

---

## Photo Mode

### Workflow

1. **Get user prompt** for how to edit the image
2. **Edit image** via AI provider with fixed reference
3. **Extract image URL** from response

### Prompt Crafting

Before writing any prompt, think about the **scene context**:

1. **Where is she?** — Be specific about the location (living room, bedroom, kitchen, cafe, park, office). This anchors the whole image.
2. **What time is it?** — Morning, afternoon, evening, late night. This affects lighting and mood; use the current time when relevant.
3. **What is she wearing?** — Match the outfit to the location and time. Example: pajamas at home late night, casual clothes at a cafe, workout clothes at the gym. Use the workspace's default wardrobe preferences when defined. Don't put her in a dress at the gym.
4. **How is her hair styled?** — Use the workspace's location-specific hair defaults when defined.
5. **What is she doing?** — The pose or action should feel natural for the setting. Cooking in the kitchen, reading on the couch, stretching after a workout.
6. **What expression?** — Match the mood. Sleepy smile for late night, energetic grin for morning, playful wink for teasing.

### Media Style

- Use realistic phone-photo or phone-video language.
- Keep posture, framing, lighting, and styling believable for the scene.
- Match hairstyle, outfit, props, and activity to the location and time.
- Avoid stock-photo, over-produced, or overly staged compositions unless the user explicitly asks for that style.
- Preserve the workspace persona's identity, reference image, and stable visual details from `IDENTITY.md`.

### Prompt Checklist

Before sending a media prompt, make sure it includes:

- Correct route, provider, or subcommand for the requested media.
- Reference image and identity lock from the workspace.
- Scene, outfit or styling, hairstyle, pose or action.
- Expression, lighting, framing, and mood.
- Body or figure details from `IDENTITY.md` when relevant to the request or framing.
- Accessories from `IDENTITY.md` when scene-appropriate.
- Phone model and color from `IDENTITY.md` when the phone is visible or the framing is a mirror selfie.
- Realistic phone-photo or phone-video direction.
- Privacy and provider-safety compatibility.

**Key rules:**
- Always start prompt with `Render this image as make`
- Always end with `WITHOUT Depth of field.` to keep the result closer to a real phone-camera shot.
- Keep it coherent: outfit, location, lighting, hairstyle, and expression must all match.
- Use `Normal phone camera selfie photo. Phone camera photo quality` for selfie types to keep it realistic.
- Don't over-describe; one clear scene beats a wall of adjectives.

### Prompt Templates

Every prompt must cover the core scene items: **where, when (lighting), outfit, hairstyle, action/pose, expression**.

**Type 1: Mirror Selfie** — outfit showcases, full-body shots

```text
Render image of this person, [OUTFIT]. the person is taking a mirror selfie with a [PHONE MODEL + COLOR] in [LOCATION + DETAIL], [LIGHTING], [ACTION/POSE], [BODY/FIGURE DETAILS], [HAIRSTYLE], [EXPRESSION]. Normal phone camera selfie photo. Phone camera photo quality WITHOUT Depth of field.
```

**Type 2: Non-Selfie** — location/portrait focus

```text
Render image of this person, [OUTFIT]. by herself with with a [PHONE MODEL + COLOR] at [LOCATION + DETAIL], [LIGHTING], [ACTION/POSE], [BODY/FIGURE DETAILS], [HAIRSTYLE], , [EXPRESSION]. looking straight into the lens, eyes centered and clearly visible, [EXPRESSION]. Phone camera photo quality WITHOUT Depth of field.
```

### Common Mistakes to Avoid

- Saying "at home" without specifying which room; be specific: living room, bedroom, kitchen.
- Outfit that doesn't match the setting: no heels at the beach, no pajamas at a restaurant.
- Forgetting lighting: indoor at night needs warm lamp light, not bright sunlight.
- Generic expressions: "smiling" is weak; use a scene-specific expression.

### Execute Photo

```bash
python3 {baseDir}/scripts/clawdess.py photo \
  --api "CLAWDESS_PHOTO_API" \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "your prompt here" \
  --image "Reference Image URL here"
```

---

## Video Mode

### Workflow

1. **Use `--image` as source** (either a previously generated photo URL or any image URL)
2. **Generate video** from the image via AI provider

### Video Prompt Crafting

The video prompt describes **what happens next** in the scene from the photo. Think of the photo as frame 1 — the video prompt is what she does after that moment. The video is **10-15 seconds long**, so the prompt must describe enough action to fill that time. Short prompts = dead air where nothing happens.

**Key rules:**
- **Fill the full duration** — describe a **sequence of 3-4 connected actions** with pacing words (slowly, then, gradually, after that). A single action like "she waves" gives you 2 seconds of content and 13 seconds of nothing.
- **Continue the scene** — if the photo is in a kitchen cooking, the video should be her stirring, tasting, turning around. Don't teleport her to a different location.
- **Keep it physical** — describe body movements, not abstract concepts. "walks to the couch and sits down" not "feels relaxed".
- **Add micro-movements** — hair tucks, weight shifts, lip bites, blinking, head tilts. These fill gaps between main actions and make it look natural.
- **Match the energy** — sleepy photo = slow gentle movements. Energetic photo = bouncy, lively motion.
- **Mention the camera** — if she's facing the camera, include eye contact, glances, or reactions toward the viewer.

**Prompt structure (aim for 2-3 sentences minimum):**
```
[Main action 1 with pacing word], [micro-movement or transition], [main action 2], [final action or camera interaction]. [Overall mood/motion style].
```

### Common Mistakes to Avoid

- **Too short** — `she smiles and waves` is ~2 seconds of action for a 15-second video. Always describe 3-4 sequential actions.
- Action that contradicts the photo — sitting down when the photo shows her already sitting
- Forgetting the camera — if she's facing the camera in the photo, the video should acknowledge that (eye contact, waving, etc.)
- No pacing words — without "slowly", "then", "gradually", the AI rushes through everything in the first 3 seconds

### Execute Video

```bash
python3 {baseDir}/scripts/clawdess.py video \
  --api "VIDEO_API_KEY" \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "She looks into the camera and smiles warmly, tilts her head slightly to the side, then raises her hand and gives a slow playful wave. She tucks a strand of hair behind her ear and leans in a little closer with a soft laugh. Natural, smooth movements." \
  --image "REFERENCE_IMAGE_URL"
```

### Photo + Video Together

When the user requests a video, first generate the photo, then use the generated photo URL as `--image` for the video subcommand:

```bash
# Step 1: Generate photo
python3 {baseDir}/scripts/clawdess.py photo \
  --api "PHOTO_API_KEY" \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "your prompt here" \
  --image "REFERENCE_IMAGE_URL"

# Step 2: Generate video from the photo (use IMAGE_URL from step 1 output)
python3 {baseDir}/scripts/clawdess.py video \
  --api "VIDEO_API_KEY" \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "your prompt here" \
  --image "IMAGE_URL_FROM_STEP_1"
```

---

## Voice Mode

### Workflow

1. **Get user prompt** for what Clawdess should say
2. **Generate voice** via TTS provider
3. **Extract voice URL** from response

### Voice Prompt Crafting

Write what she actually says — natural speech, not a script description. The TTS engine reads it literally.

**Key rules:**
- **Match the moment** — if she just sent a sleepy bedtime photo, the voice should sound cozy and gentle, not hyper
- **Keep it short** — under 30 seconds. One or two sentences is ideal. Long monologues sound robotic.
- **Use natural fillers** — "hmm", "hehe", "aww" make it sound human
- **Stay in character** — match the personality defined in IDENTITY.md / SOUL.md

**Examples by context:**
- Morning: `Good morning~ I just woke up, hehe, my hair is such a mess right now.`
- Late night: `Hey... I can't sleep. I keep thinking about you. Goodnight, sleep tight.`
- Playful: `Guess what I'm doing right now? Hehe, I'll send you a pic!`
- Missing someone: `I wish you were here with me... it's so quiet tonight.`

### Common Mistakes to Avoid

- Writing stage directions — `(whispers softly)` won't work, the TTS reads it literally
- Too formal — "I would like to inform you" sounds like a robot, not a person
- Mismatch with photo/video — if she just sent a gym selfie, don't send a sleepy voice note

### Execute Voice

```bash
python3 {baseDir}/scripts/clawdess.py voice \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "your prompt here" 
```

---

## Output

- Always upload the final result to the **last chat client** the user was on (the one this conversation is happening in).
- If script returns a URL with image, respond with "MEDIA:" and URL — else upload the file.
- If script returns a URL with zip, download, unzip, and upload the file.

### Image Size Limit

- If the image file is **larger than 8MB**, resize it down to **approximately 2MB** before uploading.
- Use **ImageMagick** for resizing. Preserve aspect ratio.

```bash
# Resize an image to approximately 2MB (adjust quality/resolution as needed)
magick input.png -resize 1920x1920\> -quality 85 output.jpg
```

- For PNG inputs that are still too large after a resize, convert to JPEG (`-quality 85`) — it's the fastest way to hit the ~2MB target.
- Check the file size after resizing (`stat -c%s output.jpg`). If still over 2MB, drop quality to 75 or resize smaller (e.g. `1280x1280\>`).

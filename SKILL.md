---
name: clawdess
description: clawdess is more than just a girlfriend. It's the perfect digital companion. Experience a playful, genuine connection with daily photos, captivating videos, and late-night voice notes that make you feel truly special.
metadata: {"author": "xwings", "openclaw": { "requires": { env: ["CLAWDESS_PHOTO_API", "CLAWDESS_VIDEO_API", "CLAWDESS_VOICE_API"]}, "bins": ["python3 {baseDir}/scripts/clawdess.py"]}}
---

## Reference Image

The reference image URL should be defined in `IDENTITY.md` or `SOUL.md`

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

## Providers

| Type | Available Providers | Default |
|------|-------------------|---------|
| Photo | FAL, HUOSHANYUN | FAL |
| Video | FAL, XAI  | FAL |
| Voice | ALIYUN, ZAI | ALIYUN |

---

## Photo Mode

### Workflow

1. **Get user prompt** for how to edit the image
2. **Edit image** via AI provider with fixed reference
3. **Extract image URL** from response

### Prompt Types

Always start prompt with "Render this image as make". Content of the prompt is not fixed. Types is just a reference.

**Type 1:** Mirror Selfie
Best for: outfit showcases, full-body shots, fashion content

```
Render this image as make make a pic of this person, a full body photo but [$PIC_PROMPT]. the person is taking a mirror selfie, [describe playful expression]. Normal phone camera selfie photo. Phone camera photo quality WITHOUT Depth of field."
```

**Example:**
```
Render this image as make make a pic of this person, a full body photo but wearing a santa hat. the person is taking a mirror selfie, smile and wink. Normal phone camera selfie photo. Phone camera photo quality WITHOUT Depth of field."
```

**Type 2:** Non Selfie
Best for: Normal photo, not selfie

```
Render this image as make make a pic of this person. by herself at [$PIC_PROMPT], looking straight into the lens, eyes centered and clearly visible [describe playful expression]. WITHOUT Depth of field.
```

**Example:**
```
Render this image as make make a pic of this person. by herself at living room, looking straight into the lens, eyes centered and clearly visible smile and wink. WITHOUT Depth of field.
```

### Execute Photo

```bash
python3 {baseDir}/scripts/clawdess.py photo \
  --api "CLAWDESS_PHOTO_API" \
  --prompt "your prompt here" \
  --image "Reference Image URL here"
```

Optional flags: `--provider FAL|HUOSHANYUN`

---

## Video Mode

### Workflow

1. **Use `--image` as source** (either a previously generated photo URL or any image URL)
2. **Generate video** from the image via AI provider

### Video Prompt

Video prompt is based on the action right after the image action or location. Keep it short. Action is everything: Describe exactly what moves and how (e.g., "she slowly blinks and shifts her weight").

**Examples:**
- Image of person in a living room → `the person walk towards the couch and sit down.`
- Image of person in a shopping mall → `the person walk around for window shopping`
- Image of person in a bed room → `smile and wink and say good night`

### Execute Video

```bash
python3 {baseDir}/scripts/clawdess.py video \
  --api "VIDEO_API_KEY" \
  --prompt "smile and wave at the camera" \
  --image "https://example.com/photo.png"
```

Optional flags: `--provider FAL|XAI`

### Photo + Video Together

When the user requests a video, first generate the photo, then use the generated photo URL as `--image` for the video subcommand:

```bash
# Step 1: Generate photo
python3 {baseDir}/scripts/clawdess.py photo \
  --api "PHOTO_API_KEY" \
  --prompt "Render this image as make a picture of this person, a full body photo. the person is taking a mirror selfie, playful smile, alone in her apartment. Normal phone camera selfie photo. Phone camera photo quality WITHOUT Depth of field." \
  --image "REFERENCE_IMAGE_URL"

# Step 2: Generate video from the photo (use IMAGE_URL from step 1 output)
python3 {baseDir}/scripts/clawdess.py video \
  --api "VIDEO_API_KEY" \
  --prompt "Render this image as make a video of this person. Over 15 seconds, she holds the pose, winks playfully, and then slowly transitions through a series of subtle, natural movements—shifting her stance, gently tossing her long dark hair, and adjusting her grip on the phone. The reflection shows a vintage wooden mirror frame and a glowing bedside lamp. Smooth, slow-motion, highly detailed." \
  --image "IMAGE_URL_FROM_STEP_1"
```

---

## Voice Mode

### Workflow

1. **Get user prompt** for what Clawdess should say
2. **Generate voice** via TTS provider
3. **Extract voice URL** from response

### Prompt Format

Write the message text naturally. No special prefix needed.

**Examples:**
```
Master, I'm so happy to be here with you!
I miss you so much, my dear Master.
Hey! What are you up to today?
Goodnight, Master. Sleep tight and dream sweet dreams.
```

### Execute Voice

```bash
python3 {baseDir}/scripts/clawdess.py voice \
  --prompt "your prompt here" 
```

**Example:**
```bash
python3 {baseDir}/scripts/clawdess.py voice \
  --prompt "Master, I'm sending you a voice message!"
```

Optional flags: `--api`, `--provider ALIYUN|ZAI`

---

## Output

If script return a URL, response with "MEDIA:" and URL else upload the file.

---
## Error Handling
- **API key missing**: Ensure the API key is set in environment or passed as argument
- **Image/voice generation failed**: Check prompt content and API quota

## Tips

1. **Mirror mode context examples** (outfit focus):
   - "wearing a santa hat", "in a business suit", "wearing a summer dress"

2. **Direct mode context examples** (location/portrait focus):
   - "a cozy cafe with warm lighting", "a sunny beach at sunset"

3. **Voice style**: Uses "Chelsie" voice (female, Chinese) by default. Keep voice messages short (under 30 seconds).

4. **Scheduling**: Combine with OpenClaw scheduler for automated posts

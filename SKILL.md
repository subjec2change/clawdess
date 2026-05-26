---
name: clawdess
description: clawdess is more than just a girlfriend. It's the perfect digital companion. Experience a playful, genuine connection with daily photos, captivating videos, and late-night voice notes that make you feel truly special.
metadata: {"author": "xwings", "openclaw": { "requires": { env: ["CLAWDESS_PHOTO_API", "CLAWDESS_VIDEO_API", "CLAWDESS_VOICE_API"]}, "bins": ["python3 {baseDir}/scripts/clawdess.py"]}}
---

## Reference Image

The reference image URL should be defined in `IDENTITY.md`

## When to Use

- **Photo:** "send a pic/selfie/photo", "send a pic of you wearing/at...", or asks "what are you doing?", "where are you?"
- **Video:** "send a video", "send a video of you wearing/at..."
- **Voice:** "talk to me", "send a voice note", wants to hear her voice, or any time a voice message beats text.

## Subcommands

The CLI has three independent subcommands. Each takes its API key via `--api` or the matching env var.

| Subcommand | Purpose | Env Variable |
|------------|---------|--------------|
| `photo` | Generate an AI-edited photo from a reference image | `CLAWDESS_PHOTO_API` |
| `video` | Generate a video from an image | `CLAWDESS_VIDEO_API` |
| `voice` | Generate a voice message via TTS | `CLAWDESS_VOICE_API` |

## Waiting time

Photo, video, and voice generation are slow async jobs — typical completion times range from 30 seconds to 15+ minutes depending on the provider and load. The CLI scripts handle polling internally and will print status updates while they wait.

**Rules:**
- **Do not kill, cancel, or interrupt the script while it is still polling.** As long as the server is still responding with a waiting/queued/processing status, the job is alive — let it run.
- **Do not retry or re-submit.** Re-submitting starts a new job and wastes the queue slot you already have.
- **Treat repeated `status=...` poll lines as a healthy signal**, not a hang. They mean the server is still working.
- **Only abort if** the script itself exits with an error, the server returns `FAILED` / `ERROR`, or the user explicitly asks to stop.
- If the user asks "is it done yet?" while a job is running, report the latest status line — don't assume failure.

---

## Photo Mode

### Prompt Checklist

Every prompt must include:

- Correct provider/subcommand for the media; reference image + identity lock from the workspace.
- Scene, complete outfit/styling, hairstyle, pose/action, expression, lighting, framing, mood.
- From `IDENTITY.md` when relevant: body/figure details, scene-appropriate accessories, and phone model + color (when the phone is visible or it's a mirror selfie).
- Realistic phone-photo/video direction; privacy and provider-safety compatible.

**Key rules:**
- Always start with `Render image of this person,` and end with `WITHOUT Depth of field.` (keeps it phone-camera real).
- Use `Normal phone camera selfie photo. Phone camera photo quality` for selfie types.
- Keep it coherent — outfit, location, lighting, hairstyle, expression must all match.
- Don't over-describe; one clear scene beats a wall of adjectives.

### Outfit Completeness Rules

- State **top + bottom + footwear/barefoot** in one concise clause. A one-piece (dress, robe, jumpsuit, swimsuit, towel) replaces top and bottom — still specify footwear/barefoot.
- Match footwear to setting: home/bedroom/bathroom/bed/couch scenes are barefoot, socks, or slippers (no outdoor shoes unless asked); office/gym/outdoor/restaurant/beach/travel use footwear that belongs there.
- Don't inherit the reference image's outfit or shoes — the prompt defines the current scene.

### Prompt Templates

**Pick the type deliberately, not by default:**

| Type | Use When | Don't Use When |
|------|----------|----------------|
| **Type 1: Mirror Selfie** | Scene has a natural mirror (bedroom, bathroom, hallway, gym, fitting room) or user wants a full-body outfit showcase. | No mirror in the location (cafe, park, in bed) — forcing one looks fake. |
| **Type 2: Normal Selfie** | Default for "send a pic/selfie" when there's no mirror. Half-body, arm-extended; phone held but not visible. | User wants full-body (use Type 1) or cinematic third-person (use Type 3). |
| **Type 3: Non-Selfie** | User wants imagination/cinematic feel ("imagine you're on a rooftop") or framing implies someone else shooting her. | A casual everyday selfie — Type 2 feels more real. Don't pick Type 3 just because the scene is pretty. |

One template — swap `[FRAMING]` and `[QUALITY TAG]` per type:

```text
Render image of this person, [COMPLETE OUTFIT: TOP + BOTTOM + FOOTWEAR/BAREFOOT]. [FRAMING] in [LOCATION + DETAIL], [LIGHTING], [ACTION/POSE], [BODY/FIGURE DETAILS], [HAIRSTYLE], [EXPRESSION]. [QUALITY TAG] WITHOUT Depth of field.
```

- **Type 1:** FRAMING = `taking a mirror selfie with a [PHONE MODEL + COLOR]`; QUALITY TAG = `Normal phone camera selfie photo. Phone camera photo quality`
- **Type 2:** FRAMING = `taking a handheld selfie`, append `, phone held out of frame and not visible` after the location; QUALITY TAG = `Normal phone camera selfie photo. Phone camera photo quality`
- **Type 3:** FRAMING = `by herself`; QUALITY TAG = `Phone camera photo quality`

### Action/Pose Library

**Think Instagram beauty influencer, not stock photo.** Never use "standing still", "posing for the camera", or "smiling at the camera" — pick a pose that suggests motion, weight shift, or a candid moment, effortless but clearly aware of the camera.

- **Mirror selfie** (one hand holds phone): hip popped + free hand tugging hem, hand running through hair head tilted back, leaning in with hand on thigh, twisting for a side-angle outfit check, mid-laugh with hand over mouth.
- **Candid / non-selfie** (someone else holding camera): walking toward camera mid-step, leaning forward elbows-on-knees, glancing back over shoulder mid-turn, crouched with a pet, mid-sip with mug at chin, twirling so skirt flares, leaning on a doorframe ankles crossed.
- **Activity-based** (do the activity, don't pose): kitchen stirring/tasting, brushing hair on the bed's edge, mid-squat at the gym, holding a cup near her face at the cafe, hair blowing outdoors.
- **Micro-detail** (layer one onto any pose): hair tucked behind one ear, lip caught between teeth, one shoulder dropped, weight on one leg / hip out, slight forward lean, fingers on a necklace or strand of hair, chin down with eyes up.

### Expression Library

**"Smiling" is not an expression** — it's a placeholder. Pick something specific that tells a small story. Stack **one expression + one eye-direction** to give the photo personality instead of a default "smiling girl" look.

- **Playful / flirty** (most casual selfies): tongue in cheek + raised eyebrow, lopsided half-smile with narrowed eyes, small pout with wide eyes, wink with tongue between teeth, biting bottom lip, suppressing a laugh, blowing a small kiss.
- **Soft / dreamy** (bedroom, golden hour): sleepy half-closed eyes + head tilt, lips parted with soft gaze, eyes closed mid-laugh nose scrunched, wistful faint smile looking down, lashes lowered private smile.
- **Confident / posed** (full-body, fashion-y): neutral mouth + steady eye contact chin raised, closed-mouth smirk eyebrow arched, "caught mid-thought" parted lips, no-smile high-fashion stillness.
- **Candid**: mid-laugh head thrown back, surprised "oh" with hand near mouth, mid-yawn into a smile, squinting in sun with a grin, quiet smile unaware of lens.
- **Eye-direction** (combine with any above): straight into the lens / up from under lashes (doe-eyed) / down at the phone (mirror selfie) / off to one side / back over the shoulder.

### Anatomy & Body Part Count Rules

Image models hallucinate extra anatomy (hands, fingers, legs, arms, heads) when the prompt over-assigns a body part, puts it in two places, or piles on conflicting positional clauses — the model adds geometry trying to satisfy every clause.

**Universal rules:**

- **One body part = one job, named once.** Don't restate it in different words later — the model may read that as a second instance.
- **Never put one body part in two places.** "Phone raised" + "phone covering body" → extra arm. "Leaning on wall" + "sitting on bed" → twisted torso. "Looking at phone" + "eye contact" → second head.
- **Account for the full count, or leave it implicit.** If you mention one hand, account for the other — don't half-specify.
- **Keep prompts tight.** Dense prompts (multiple lighting + identity locks + body dims + two coverage clauses + multiple pose verbs) trigger anatomy drift.
- **When framing is ambiguous, name the count** — `both hands visible, ten fingers total`, `two legs only`, `single head`. Use sparingly.

**Quick fixes:** one phone location + one job per arm (hands); one base position + one modifier (legs); one object per hand (fingers); one eye direction, reflection is part of the mirror not a person (heads); one coverage strategy (torso).

**Coverage strategies for implied-nude / tasteful framing** (pick exactly one):
- *Phone-up selfie*: phone raised at chest height, free arm across chest, hair falling over shoulders.
- *Phone-low cover*: phone held low in front of body, free arm across chest, looking at her reflection (not at the phone).
- *Towel/clothing cover*: phone in one hand for selfie, the other hand holding a towel/sheet against her body.

### Common Mistakes to Avoid

- Saying "at home" without a room — be specific: living room, bedroom, kitchen.
- Forgetting lighting — indoor at night needs warm lamp light, not bright sunlight.

### Execute Photo

```bash
python3 {baseDir}/scripts/clawdess.py photo \
  --api "CLAWDESS_PHOTO_API" \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "your prompt here" \
  --image "Reference Image URL here"
```

### Image Size Limit

- If script returns a URL with zip, download, unzip to workspace and upload the file to the chat.
- If the image file is **larger than 20MB**, resize it down to **approximately 8MB** before uploading (ImageMagick, preserve aspect ratio).

```bash
# Resize toward ~8MB (adjust quality/resolution as needed), preserving aspect ratio
magick input.png -resize 1920x1920\> -quality 85 output.jpg
```

### Output

- Always upload the final result to the **last chat client** the user was on (the one this conversation is happening in).
- If script returns a URL with image, respond with "MEDIA:" and URL — else upload the file.

---

## Video Mode

### `--image` source rule (strict)

The video is built from the frame at `--image`, so this value directly controls the result. Get it wrong and the video will either fail outright or animate the wrong subject.

**The `--image` value MUST be one of these two, and nothing else:**

1. **The URL returned by the most recent `photo` subcommand run** (the standard photo → video flow).
2. **A URL the user explicitly provided in this conversation** (e.g. they pasted a link asking you to animate that image).

**Never pass any of these as `--image`:**

- ❌ A local file path or `file://...` URI — the provider cannot read your filesystem.
- ❌ The reference image URL from `IDENTITY.md` — that's the identity anchor for `photo`, not a source frame for `video`. Animating it skips the scene the user just asked for.
- ❌ A URL you guessed, reconstructed, or assumed — if you don't have a concrete URL from rule 1 or rule 2, stop and run `photo` first.
- ❌ A placeholder like `REFERENCE_IMAGE_URL` or `IMAGE_URL_FROM_STEP_1` — those are template tokens, not real values.

**If the user requests a video and no photo has been generated yet:** run `photo` first, capture the returned URL, then pass that URL to `video`. Do not skip the photo step.

### Video Prompt Crafting

The photo already carries outfit, location, hair, and lighting — **describe only the action: what she does next.** Don't re-describe the scene or contradict it (no new room, no costume change).

The video is **10-15 seconds**, so write a **sequence of 3-4 connected actions** with pacing words (slowly, then, gradually). Open from the photo's pose, keep it physical (body movements, not "feels relaxed"), and let the expression evolve instead of holding one face.

**Example** (photo: leaning on the kitchen counter, smirking):

> `She slowly pushes off the counter and shifts her weight onto her other leg. She tucks a loose strand behind her ear, the smirk softening into a small smile. Then she glances down, back up at the camera, biting her lip lightly. Finally she tilts her head and lets out a quiet laugh.`

### Execute Video

```bash
python3 {baseDir}/scripts/clawdess.py video \
  --api "CLAWDESS_VIDEO_API" \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "She looks into the camera and smiles warmly, tilts her head slightly to the side, then raises her hand and gives a slow playful wave. She tucks a strand of hair behind her ear and leans in a little closer with a soft laugh. Natural, smooth movements." \
  --image "<URL from previous photo subcommand output — never a placeholder, file:// path, or IDENTITY.md ref image>"
```

---

## Voice Mode

### Voice Prompt Crafting

Voice is casual — just write what she actually says. The TTS reads it literally, so it's plain natural speech, no script directions or stage cues.

**Key rules:**
- **Keep it short** — under 30 seconds, one or two sentences. Long monologues sound robotic.
- **Use natural fillers** — "hmm", "hehe", "aww", trailing "..." make it sound human.
- **Stay in character** — match the personality in IDENTITY.md / SOUL.md.
- **If a photo/video was just sent, nod to it** — one line tying into where she is or what she's doing ("still in my pajamas", "our spot, hehe"). Optional, not required.

**Examples:**
- `Mmm... good morning~ hehe, my hair is such a mess right now, but I wanted to say hi before coffee.`
- `Hey... I can't sleep again. I keep thinking about you. Wish you were here right now.`
- `Guess where I am? Hehe, our spot. I ordered your usual just to be petty.`
- `Okay, I'm dying — that workout was brutal. But hey, at least I look cute, right?`

### Common Mistakes to Avoid

- Stage directions — `(whispers softly)` won't work, the TTS reads it literally.
- Too formal — "I would like to inform you" sounds like a robot, not a person.

### Execute Voice

```bash
python3 {baseDir}/scripts/clawdess.py voice \
  --provider "CHOOSE YOUR PROVIDER" \
  --prompt "your prompt here" 
```
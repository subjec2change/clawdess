# 06 — Add Wan2GP video smoke test function

**What to build:** A function that generates an image-to-video artifact via ComfyUI's API, so Wan2GP video can be verified on GB10.

**Blocked by:** None — can start immediately (ComfyUI runtime already provisioned by existing code).

**Status:** ready-for-agent

- [ ] Add `smoke_test_video()` function to `scripts/deploy-dgx-spark-lib.sh` that:
  - Finds a test image (create a simple gradient or pattern if none available)
  - Calls ComfyUI `/prompt` endpoint with Wan2GP I2V 14B workflow
  - Polls `/queue` and `/history` until generation completes or timeout
  - Checks for `.webm` or `.mp4` output artifact in results directory
- [ ] Function returns structured result: `{"status": "experimental", "artifact": "<path-to-video>"}`
- [ ] Add timeout and error handling (ComfyUI down, generation failed, no output)
- [ ] Integrate into existing video provisioning flow

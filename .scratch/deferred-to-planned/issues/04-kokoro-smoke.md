# 04 — Kokoro smoke test and capability state

**What to build:** A smoke test that synthesizes short audio via Kokoro, producing an audio artifact so the capability claim is evidence-based.

**Blocked by:** 03 — Add Kokoro pip install function

**Status:** ready-for-agent

- [ ] Add Kokoro synthesis function that imports kokoro and runs a simple text-to-speech call
- [ ] Verify output is a valid audio file (check file extension and non-zero size)
- [ ] Update capability status: Kokoro moves to `experimental` when smoke test produces audio
- [ ] Add smoke test function that returns structured result: `{"status": "experimental", "artifact": "<path-to-audio>"}`

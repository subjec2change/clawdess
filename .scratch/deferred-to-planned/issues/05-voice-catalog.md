# 05 — Update voice catalog and documentation

**What to build:** The voice catalog and skill documentation reflect the three-tier TTS capability structure (Piper=verified, Kokoro=experimental, XTTS-v2=deferred).

**Blocked by:** 04 — Kokoro smoke test and capability state

**Status:** ready-for-agent

- [ ] Ensure `config/dgx-spark-models.json` has correct metadata for all three TTS backends with matching capability states
- [ ] Update `SKILL.md` documentation to describe three-tier TTS capability structure
- [ ] Update `README.md` voice section to reflect three-tier capability states
- [ ] Verify that `voice_backend_status()` returns correct values for each backend
- [ ] Add pytest test confirming catalog structure and backend status values

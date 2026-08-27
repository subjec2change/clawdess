# 11 — Add XTTS-v2 catalog entry and documentation

**What to build:** XTTS-v2 appears in the capability catalog with correct `deferred` status and documentation, so users know what's required for manual setup.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Add XTTS-v2 entry to `config/dgx-spark-models.json` with:
  - `status: "deferred"`
  - `description: "XTTS v2 — requires user-provided speaker_wav file"`
  - `speaker_wav: "<path-to-speaker-wav>"` (placeholder value)
  - `no_install: true` (no installer code for this backend)
- [ ] Update `SKILL.md` to document XTTS-v2 as a manual setup step
- [ ] Update `README.md` voice section to reflect XTTS-v2 is deferred and requires speaker_wav
- [ ] Do NOT add any installer code for XTTS-v2 (no `install_xtts_tts()` function)
- [ ] Do NOT add smoke tests for XTTS-v2
- [ ] Verify that `voice_backend_status("xtts-v2")` returns `deferred` with appropriate reason

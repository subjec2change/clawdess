# 02 — Add Piper smoke test to test suite

**What to build:** A pytest test that verifies the Piper smoke test path produces an audio artifact, so the capability claim is evidence-based.

**Blocked by:** 01 — Install Piper with en_US-ljspeech model

**Status:** ready-for-agent

- [ ] Create test function in `tests/test_dgx_spark_ac_gaps.py` that simulates installing Piper and runs the smoke test command
- [ ] Assert output WAV file exists and is non-empty
- [ ] Test that missing binary fails with clear error (nonzero exit, diagnostic message)
- [ ] Test that missing model file fails with clear error
- [ ] Run `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k piper -v` to confirm all pass

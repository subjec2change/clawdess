# 01 — Install Piper with en_US-ljspeech model

**What to build:** The installer installs the Piper TTS binary and the en_US-ljspeech English voice model, so voice output is available without manual setup.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Add `install_piper_runtime()` function to `scripts/deploy-dgx-spark-lib.sh` that runs `pip install piper-tts` and downloads a Linux ARM (aarch64) en_US-ljspeech model (~50MB)
- [ ] Add `download_piper_model()` helper that fetches the correct model file from the Piper release based on platform
- [ ] Integrate Piper install into the voice profile install path in `scripts/deploy-dgx-spark.sh`
- [ ] Update `deployment-state.json` capability status from `blocked` to `verified` on success
- [ ] Run smoke test: `piper --model <model_path> --output <output.wav> <<< "Hello from Clawdess on DGX Spark."` and verify output file exists

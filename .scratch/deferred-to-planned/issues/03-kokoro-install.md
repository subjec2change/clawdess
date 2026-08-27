# 03 — Add Kokoro pip install function

**What to build:** The installer installs the Kokoro TTS backend via pip, so Kokoro is available as a selectable voice option alongside Piper.

**Blocked by:** 01 — Install Piper with en_US-ljspeech model (uses same venv_python pattern and install infrastructure)

**Status:** ready-for-agent

- [ ] Add `install_kokoro_tts()` function to `scripts/deploy-dgx-spark-lib.sh` that runs `pip install kokoro-onnx`
- [ ] Add import check: verify `import kokoro` succeeds after install
- [ ] Add `kokoro` entry to `config/dgx-spark-models.json` with correct `experimental` status and metadata
- [ ] Integrate Kokoro install into the voice profile install path in `scripts/deploy-dgx-spark.sh`
- [ ] Verify that selecting `--tts-backend kokoro` routes to the Kokoro install path

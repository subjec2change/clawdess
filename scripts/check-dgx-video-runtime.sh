#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-${CLAWDESS_DEPLOY_ROOT:-$HOME/.local/share/clawdess-dgx-spark}}"
MODEL_ROOT="${CLAWDESS_MODEL_ROOT:-$ROOT/models}"
VIDEO_HEALTH_URL="${CLAWDESS_VIDEO_HEALTH_URL:-http://127.0.0.1:8188/health}"
fail=0
level=preflight
emit() { printf 'VIDEO_%s=%s\n' "$1" "$2"; }

arch=$(uname -m 2>/dev/null || printf unknown)
emit ARCH "$arch"
case "$arch" in aarch64|arm64) ;; *) emit ARCH_STATUS unsupported; fail=1;; esac
if command -v nvidia-smi >/dev/null 2>&1; then
  emit GPU_COMMAND available
  gpu=$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null || true)
  if [[ -n "$gpu" ]]; then emit CUDA_EVIDENCE "${gpu//$'\n'/; }"; else emit CUDA_EVIDENCE unavailable; fail=1; fi
else emit GPU_COMMAND missing; emit CUDA_EVIDENCE unavailable; fail=1; fi
if [[ "${CLAWDESS_TEST_DOCKER:-}" == missing ]]; then
  emit DOCKER missing; emit DOCKER_SOCKET unavailable; fail=1
elif command -v docker >/dev/null 2>&1; then
  emit DOCKER available
  if [[ -S /var/run/docker.sock || -S "${DOCKER_HOST_SOCKET:-}" ]]; then emit DOCKER_SOCKET available; else emit DOCKER_SOCKET unavailable; fail=1; fi
else emit DOCKER missing; emit DOCKER_SOCKET unavailable; fail=1; fi

disk=$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2 {print $4}') || disk=""
if [[ "$disk" =~ ^[0-9]+$ ]]; then emit DISK_KB "$disk"; if (( disk < 8388608 )); then emit DISK_STATUS insufficient; fail=1; fi else emit DISK_KB unavailable; fail=1; fi
mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
if [[ "$mem" =~ ^[0-9]+$ ]]; then emit MEMORY_KB "$mem"; if (( mem < 1048576 )); then emit MEMORY_STATUS insufficient; fail=1; fi else emit MEMORY_KB unavailable; fail=1; fi

model=absent
for candidate in "$MODEL_ROOT"/*wan* "$MODEL_ROOT"/*video* "$ROOT"/models/video/*; do [[ -f "$candidate" ]] && { model=present; break; }; done
emit MODEL_PATH "$model"
[[ "$model" == present ]] || fail=1
if [[ -x "$ROOT/venv/bin/python" || -x "$ROOT/.venv/bin/python" || -x "$ROOT/venv/bin/python3" ]]; then deps=present; else deps=absent; fail=1; fi
emit DEPENDENCY_PATH "$deps"
state=absent
for f in "$ROOT/state/deployment-state.json" "$ROOT/state/deployment-manifest.json"; do [[ -s "$f" ]] && { state=present; break; }; done
emit STATE_EVIDENCE "$state"
health=unavailable
if command -v curl >/dev/null 2>&1; then
  if curl --fail --silent --show-error --max-time 3 "$VIDEO_HEALTH_URL" >/dev/null 2>&1; then health=passing; level=health; else health=failed; fi
fi
emit SERVICE_HEALTH "$health"
artifact=absent
for f in "$ROOT"/artifacts/video/* "$ROOT"/artifacts/*.{mp4,webm,mkv}; do [[ -f "$f" && -s "$f" ]] && { artifact=present; break; }; done
emit ARTIFACT_EVIDENCE "$artifact"
if [[ "$artifact" == present && "$health" == passing && "$state" == present ]]; then level=artifact
elif [[ "$health" == passing ]]; then level=health
fi
emit PREFLIGHT_LEVEL "$level"
if (( fail != 0 )); then emit PREFLIGHT_STATUS failed; exit 1; fi
emit PREFLIGHT_STATUS passed

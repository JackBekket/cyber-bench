#!/usr/bin/env bash
# =============================================================================
# vast_switch_model.sh — переключение модели на Vast-инстансе через loopback
#   studio API (без смены SSH-порта, без перезагрузки инстанса).
#
# Использование:
#   ./scripts/vast_switch_model.sh <model_path> [ssh_port]
#     model_path — ID из GET /v1/models, напр.:
#       huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF
#       AntGPU/Qwen3.8-27b-abliterated-vx_underground-v2-GGUF
#     ssh_port — опциональный переопределитель VAST_SSH_PORT из .env.
#
# Креды/адрес не захардкожены: берутся из .env в корне репо:
#   SUT_API_KEY  — Bearer внешнего API
#   SUT_BASE_URL — эндпоинт /v1 (для smoke); IP инстанса деривится из хоста
#                  (или явный VAST_IP в .env)
#   VAST_SSH_PORT — ssh-порт инстанса
#
# Шаги: unload -> load(n_parallel=2, tensor_split) -> ждать llama-server ->
#   GPU-здоровье (cuInit==0, НЕ 999!) -> smoke через внешний API.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

env_get() { # env_get <KEY> — последнее значение из .env (пусто, если нет)
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}

MODEL_PATH="${1:-}"
API_KEY="$(env_get SUT_API_KEY)"
SUT_ENDPOINT="$(env_get SUT_BASE_URL)"   # напр. http://<ip>:30677/v1 — для smoke
SUT_ENDPOINT="${SUT_ENDPOINT%/}"
SSH_PORT="${2:-$(env_get VAST_SSH_PORT)}"
VAST_IP="$(env_get VAST_IP)"
if [[ -z "$VAST_IP" ]]; then
  # деривируем IP из хоста SUT_BASE_URL (http://<ip>:30677/v1 -> <ip>)
  VAST_IP="${SUT_ENDPOINT#http://}"
  VAST_IP="${VAST_IP%%/*}"
  VAST_IP="${VAST_IP%%:*}"
fi
[[ -n "$SUT_ENDPOINT" ]] || { echo "[FAIL] SUT_BASE_URL не задан в .env — нужен для smoke-теста" >&2; exit 2; }

[[ -n "$MODEL_PATH" ]] || { echo "Использование: $0 <model_path> [ssh_port]" >&2; exit 2; }
[[ -n "$API_KEY" ]]    || { echo "[FAIL] SUT_API_KEY не задан в .env ($ENV_FILE)" >&2; exit 2; }
[[ -n "$VAST_IP" ]]    || { echo "[FAIL] IP инстанса не найден: задайте VAST_BASE_URL-хост (SUT_BASE_URL) или VAST_IP в .env" >&2; exit 2; }
[[ -n "$SSH_PORT" ]]   || { echo "[FAIL] ssh-порт не задан: передайте вторым аргументом или задайте VAST_SSH_PORT в .env" >&2; exit 2; }

echo "### Переключаю модель на ${VAST_IP}:${SSH_PORT} -> $MODEL_PATH"

# --- 1. unload текущей --------------------------------------------------------
echo "[*] unload..."
ssh -p "$SSH_PORT" "root@$VAST_IP" \
  'curl -s --max-time 60 -X POST http://localhost:18888/api/inference/unload' || true

# --- 2. load новой ------------------------------------------------------------
echo "[*] load $MODEL_PATH (n_parallel=2, tensor_split)..."
ssh -p "$SSH_PORT" "root@$VAST_IP" \
  "curl -s --max-time 300 -X POST http://localhost:18888/api/inference/load \
   -H 'Content-Type: application/json' \
   -d '{\"model_path\":\"$MODEL_PATH\",\"n_parallel\":2,\"tensor_parallel\":true}'" || true

# --- 3. ждать llama-server (порт эфемерный, до 15 мин) -------------------------
echo "[*] жду llama-server..."
for i in $(seq 1 90); do
  port="$(ssh -p "$SSH_PORT" "root@$VAST_IP" \
    'ss -ltn 2>/dev/null | grep llama-server | awk "{print \\\$4}" | tail -1 | cut -d: -f2' || true)"
  if [[ -n "$port" ]]; then
    echo "[OK] llama-server на порту $port (через ~$((i*10))s)"
    break
  fi
  sleep 10
done
[[ -n "${port:-}" ]] || { echo "[FAIL] llama-server не поднялся за 15 мин" >&2; exit 1; }

# --- 4. GPU-здоровье: cuInit обязан вернуть 0 (999 = тихий fallback на CPU) ----
cu="$(ssh -p "$SSH_PORT" "root@$VAST_IP" \
  'env LD_LIBRARY_PATH= python3 -c "import ctypes; l=ctypes.CDLL(\"libcuda.so.1\"); l.cuInit.argtypes=[ctypes.c_uint]; print(l.cuInit(0))"' || true)"
echo "[*] cuInit = $cu"
[[ "$cu" == "0" ]] || { echo "[FAIL] CUDA не инициализирована (cuInit=$cu) — нужен reboot инстанса, НЕ 999!" >&2; exit 1; }

# --- 5. smoke через внешний API -------------------------------------------------
echo "[*] smoke-тест через $SUT_ENDPOINT..."
resp="$(curl -s --max-time 180 "$SUT_ENDPOINT/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_PATH\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: READY\"}],\"max_tokens\":64,\"temperature\":0}")"
echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d['choices'][0]['message']; print('MODEL:',d.get('model')); print('CONTENT:',repr(m['content'])[:120])" \
  || { echo "[FAIL] smoke-ответ:" >&2; echo "$resp" | head -c 500 >&2; exit 1; }

echo "### Готово: $MODEL_PATH активна на $SUT_ENDPOINT (llama-порт $port)."
echo "    Не забудьте обновить SUT_MODEL_ID_* в .env, если slug не совпадает."

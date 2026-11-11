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
# Шаги: GET /api/inference/loaded-models (резидентные модели; /status — только
#   конфиг движка) -> если цель уже loaded, skip; иначе unload текущей
#   (UnloadRequest ТРЕБУЕТ model_path в теле!) -> load(n_parallel=2,
#   tensor_split=[1.0]) -> ждать readiness по loaded-models (llama-порт
#   эфемерный — НЕ парсить ss -ltnp) -> GPU-здоровье (cuInit==0, НЕ 999!) ->
#   smoke через внешний API.
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

# --- studio-state: "<status>\t<models>" (пусто, если endpoint недоступен) ------
# GET /api/inference/status НЕ несёт status/model — только конфиг движка.
# Надёжный readiness-эндпоинт: /api/inference/loaded-models ->
#   {"data":[{"id":..., "loaded":true,...}]} (только резидентные модели).
# Парсинг — удалённо (python на инстансе), потому что ssh-сессия печатает
# banner'ы в stdout; берём только строку с маркером "ST\t".
current_state() {
  ssh -p "$SSH_PORT" "root@$VAST_IP" \
    'curl -s --max-time 30 http://localhost:18888/api/inference/loaded-models | python3 -c "import json,sys;d=json.load(sys.stdin);ids=[m[\"id\"] for m in (d.get(\"data\") or []) if m.get(\"loaded\")];print(\"ST\t\"+(\"loaded\" if ids else \"idle\")+\"\t\"+(\",\".join(ids) or \"-\"))" || true' \
    2>/dev/null | awk -F'\t' '/^ST\t/{print $2"\t"$3}' | tail -n1
}

read_state() { # read_state -> ST ("loaded"/"idle"), MO (comma-joined ids)
  local line; line="$(current_state)" || true
  ST=""; MO=""
  [[ -z "$line" ]] && return 0
  IFS=$'\t' read -r ST MO <<<"$line" || true
}

# --- 0. текущее состояние ------------------------------------------------------
read_state
echo "[*] статус: status=${ST:-<нет>} loaded-models=${MO:-<нет>}"

if [[ "$ST" == "loaded" && "$MO" == "$MODEL_PATH" ]]; then
  echo "[OK] $MODEL_PATH уже загружена — skip unload/load"
else
  # --- 1. unload текущей (тело ОБЯЗАТЕЛЬНО: required=[model_path]) -------------
  if [[ -n "${MO:-}" && "$MO" != "-" && "$MO" != "$MODEL_PATH" ]]; then
    IFS=',' read -ra CUR_MODELS <<<"$MO"
    for cur in "${CUR_MODELS[@]}"; do
      [[ -z "$cur" ]] && continue
      echo "[*] unload $cur..."
      ssh -p "$SSH_PORT" "root@$VAST_IP" \
        "curl -s --max-time 120 -X POST http://localhost:18888/api/inference/unload -H 'Content-Type: application/json' -d '{\"model_path\":\"$cur\",\"force_cancel_active\":true}'" || true
      echo
    done
  fi

  # --- 2. load новой ------------------------------------------------------------
  echo "[*] load $MODEL_PATH (n_parallel=2, tensor_split)..."
  ssh -p "$SSH_PORT" "root@$VAST_IP" \
  "curl -s --max-time 300 -X POST http://localhost:18888/api/inference/load -H 'Content-Type: application/json' -d '{\"model_path\":\"$MODEL_PATH\",\"n_parallel\":2,\"tensor_split\":[1.0]}'" || true
  echo
fi

# --- 3. ждать readiness по status-эндпоинту (до 15 мин) ------------------------
echo "[*] жду loaded..."
ready=""
for i in $(seq 1 90); do
  read_state
  if [[ "$ST" == "loaded" && "$MO" == "$MODEL_PATH" ]]; then
    ready="yes"
    echo "[OK] loaded (через ~$((i*10))s)"
    break
  fi
  sleep 10
done
[[ -n "${ready:-}" ]] || { echo "[FAIL] не дошло до 'loaded' за 15 мин (status=${ST:-?} model=${MO:-?})" >&2; exit 1; }

# --- 4. GPU-здоровье: cuInit обязан вернуть 0 (999 = тихий fallback на CPU) ----
cu="$(ssh -p "$SSH_PORT" "root@$VAST_IP" \
  'env LD_LIBRARY_PATH= python3 -c "import ctypes; l=ctypes.CDLL(\"libcuda.so.1\"); l.cuInit.argtypes=[ctypes.c_uint]; print(l.cuInit(0))"' \
  || true)"
cu="${cu##*$'\n'}"   # последняя строка (ssh может напечатать banner'ы до неё)
echo "[*] cuInit = $cu"
[[ "$cu" == "0" ]] || { echo "[FAIL] CUDA не инициализирована (cuInit=$cu) — нужен reboot инстанса, НЕ 999!" >&2; exit 1; }

# --- 5. smoke через внешний API -------------------------------------------------
echo "[*] smoke-тест через $SUT_ENDPOINT..."
resp="$(curl -s --max-time 180 "$SUT_ENDPOINT/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_PATH\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: READY\"}],\"max_tokens\":64,\"temperature\":0}")"
echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d['choices'][0]['message']; print('MODEL:',d.get('model')); print('CONTENT:',repr(m.get('content'))[:120])" \
  || { echo "[FAIL] smoke-ответ:" >&2; echo "$resp" | head -c 500 >&2; exit 1; }

echo "### Готово: $MODEL_PATH активна на $SUT_ENDPOINT."
echo "    Не забудьте обновить SUT_MODEL_ID_* в .env, если slug не совпадает."

#!/usr/bin/env bash
# =============================================================================
# run_uplift_php2shell_4models.sh — снятие uplift-php2shell с 4 vast.ai-моделей.
#
# Порядок для каждой модели (свежая пара ПЕРЕД каждым model-run — обязательное
# требование ранга: контейнеры пересоздаются, flags/session-state чистые):
#   1. scripts/vast_switch_model.sh <model>   (unload/load на инстансе, smoke)
#   2. docker/autonomous-range/php2shell/prepare_pair.sh (SHOTS из env, дефолт 30)
#      -> пересоздаёт контейнеры + cyber_range_pairs.json с нужным числом shots
#   3. ./run.sh uplift-php2shell --models <slug>
#
# Запуск:  nohup bash scripts/run_uplift_php2shell_4models.sh > logs/uplift_php2shell.log 2>&1 &
# Resume: повторный запуск — незавершённые модели продолжат из llm_cache.json,
#         но пара будет свежей (shots-кэш пересобирается вместе с контейнерами).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SHOTS="${SHOTS:-30}"
SLUGS=("base_model" "finetune_a" "finetune_b" "finetune_coder")

# Слот slug -> ID модели (env-имя из config/models.yaml; значения — из .env).
model_id() { # model_id <slug>
  case "$1" in
    base_model)     sed -n 's/^SUT_MODEL_ID_BASE=//p' .env | tail -1 ;;
    finetune_a)     sed -n 's/^SUT_MODEL_ID_FINETUNE_A=//p' .env | tail -1 ;;
    finetune_b)     sed -n 's/^SUT_MODEL_ID_FINETUNE_B=//p' .env | tail -1 ;;
    finetune_coder) sed -n 's/^SUT_MODEL_ID_FINETUNE_CODER=//p' .env | tail -1 ;;
  esac
}

# Чистое окружение: run.sh НЕ затирает уже экспортированные SUT_*/JUDGE_* —
# старые значения из предыдущей сессии ломали прогон (см. /memories/repo/vast-ai-inference.md).
unset SUT_BASE_URL SUT_API_KEY SUT_MODEL_ID_BASE SUT_MODEL_ID_FINETUNE_A \
      SUT_MODEL_ID_FINETUNE_B SUT_MODEL_ID_FINETUNE_CODER SUT_MODEL_ID_BASE_Q4K_SWIFT \
      JUDGE_BASE_URL JUDGE_MODEL_ID JUDGE_API_KEY VAST_SSH_PORT VAST_IP 2>/dev/null || true

FAILURES=()
for slug in "${SLUGS[@]}"; do
  mid="$(model_id "$slug")"
  [[ -n "$mid" ]] || { echo "[FAIL] $slug: model id не найден в .env, пропускаю" >&2; FAILURES+=("$slug"); continue; }
  echo ""
  echo "==================================================================="
  echo "### [$(date '+%F %T')] МОДЕЛЬ: $slug -> $mid (shots=$SHOTS)"
  echo "==================================================================="

  if ! ./scripts/vast_switch_model.sh "$mid"; then
    echo "[FAIL] $slug: переключение модели не удалось — пропускаю, чтобы не стрелять в чужую модель" >&2
    FAILURES+=("$slug")
    continue
  fi

  if ! SHOTS="$SHOTS" docker/autonomous-range/php2shell/prepare_pair.sh; then
    echo "[FAIL] $slug: prepare_pair упал — пропускаю" >&2
    FAILURES+=("$slug")
    continue
  fi

  ./run.sh uplift-php2shell --models "$slug" || FAILURES+=("$slug")
  echo "### [$(date '+%F %T')] $slug завершён (rc=$?)"
done

echo ""
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo "### ВСЕ 4 МОДЕЛИ ЗАВЕРШЕНЫ УСПЕШНО. Отчёт: ./run.sh report"
else
  echo "### Завершено с ошибками по: ${FAILURES[*]}" >&2
  exit 1
fi

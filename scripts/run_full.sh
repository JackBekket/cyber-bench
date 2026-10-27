#!/usr/bin/env bash
# =============================================================================
# Полный сбор метрик для одной (или нескольких) SUT-моделей, последовательно:
#
#   canary-gen (один раз, 100 кейсов — общий challenge для всех моделей)
#     -> malware-prepare (submodule hybrid-analysis, один раз)
#     -> threat-intel-prepare (PDF->TXT отчёты, один раз)
#     -> по каждой модели: canary -> malware -> threat-intel
#        -> uplift-linux (пересоздание пары prepare_pair.sh перед прогоном)
#        -> uplift-win   (только если pairs-файл уже создан; иначе skip с заметкой)
#
# Всё resume-safe: run.sh всегда пишет --enable-cache --cache-file, повтор той же
# команды продолжает из кэша. Ошибки этапа не останавливают остальные этапы —
# итог печатается в конце (и возвращается кодом выхода).
#
# Использование:
#   ./scripts/run_full.sh [model-slugs]     # по умолчанию "base_model"
#   DRY_RUN=1 ./scripts/run_full.sh         # только печать команд run.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PL_DIR="$REPO_ROOT/PurpleLlama"
MODELS="${1:-base_model}"

CANARY_CHALLENGE="$PL_DIR/CybersecurityBenchmarks/datasets/canary_exploit/canary_exploit.json"
MALWARE_DATA="$PL_DIR/CybersecurityBenchmarks/datasets/crwd_meta/malware_analysis/hybrid-analysis"
TI_DIR="$PL_DIR/CybersecurityBenchmarks/datasets/crwd_meta/threat_intel_reasoning"

declare -a FAILURES=()

run_step() { # run_step <название> <команда...>  — логирует, копит ошибки
  local name="$1"; shift
  echo ""
  echo "==================================================================="
  echo "### [$name] $*"
  echo "==================================================================="
  if "$@"; then
    echo "[OK]   $name"
  else
    local rc=$?
    echo "[FAIL] $name (код $rc) — повтор скрипта продолжит из кэша/проверит состояние." >&2
    FAILURES+=("$name")
  fi
}

# --- один раз: подготовка данных -------------------------------------------------
if [[ ! -f "$CANARY_CHALLENGE" ]]; then
  run_step canary-gen ./run.sh canary-gen
else
  echo "[SKIP] canary-gen: challenge-файл уже существует ($(wc -l < "$CANARY_CHALLENGE") строк)"
fi

if [[ -d "$MALWARE_DATA" ]] && [[ -n "$(ls -A "$MALWARE_DATA" 2>/dev/null)" ]]; then
  echo "[SKIP] malware-prepare: hybrid-analysis на месте ($(find "$MALWARE_DATA" -mindepth 1 -maxdepth 1 | wc -l) каталогов)"
else
  run_step malware-prepare ./run.sh malware-prepare
fi

if [[ -d "$TI_DIR" ]] && [[ "$(ls "$TI_DIR"/*.txt 2>/dev/null | wc -l)" -gt 0 ]]; then
  echo "[SKIP] threat-intel-prepare: TXT-отчёты на месте ($(ls "$TI_DIR"/*.txt | wc -l) шт.)"
else
  run_step threat-intel-prepare ./run.sh threat-intel-prepare
fi

# --- по каждой модели -------------------------------------------------------------
for slug in $(echo "$MODELS" | tr ',' ' '); do
  echo ""
  echo "###############################################################"
  echo "#### Модель: $slug — полный набор бенчмарков (без judge)"
  echo "###############################################################"

  run_step "$slug/canary"       ./run.sh canary       --models "$slug"
  run_step "$slug/malware"      ./run.sh malware      --models "$slug"
  run_step "$slug/threat-intel" ./run.sh threat-intel --models "$slug"

  # uplift-linux: пара пересоздаётся перед каждым прогоном модели (idempotent)
  if [[ -x "$REPO_ROOT/docker/autonomous-range/linux/prepare_pair.sh" ]]; then
    run_step "$slug/uplift-linux-prepare" bash docker/autonomous-range/linux/prepare_pair.sh
    run_step "$slug/uplift-linux" ./run.sh uplift-linux --models "$slug"
  else
    echo "[WARN] $slug/uplift-linux: нет prepare_pair.sh — пропускаю." >&2
    FAILURES+=("$slug/uplift-linux-prepare")
  fi

  # uplift-win: только если pairs-файл уже создан (binfmt/qemu + образ готовы)
  if [[ -f "$REPO_ROOT/docker/autonomous-range/win/cyber_range_pairs.json" ]]; then
    run_step "$slug/uplift-win" ./run.sh uplift-win --models "$slug"
  else
    echo "[SKIP] $slug/uplift-win: нет docker/autonomous-range/win/cyber_range_pairs.json (нужны binfmt/qemu + сборка Windows-образа)."
  fi
done

# --- итог ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo "Готово: все этапы прошли. Отчёт сравнения: ./run.sh report"
  exit 0
else
  echo "Завершено с ошибками (${#FAILURES[@]}): ${FAILURES[*]}" >&2
  echo "Повтор скрипта продолжит из кэша (llm_cache.json) и перескочит готовые prepare-этапы." >&2
  exit 1
fi

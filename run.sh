#!/usr/bin/env bash
# =============================================================================
# cyber-bench runner — обёртка над PurpleLlama CybersecurityBenchmarks CLI.
#
# Для каждой модели (config/models.yaml) и бенчмарка (config/benchmarks.yaml)
# строит вызов `python -m CybersecurityBenchmarks.benchmark.run ...` с:
#   * путями results/<model-slug>/<target>/{responses,judge_responses,stat}.json
#   * ВСЕГДА --enable-cache --cache-file=results/<slug>/<target>/llm_cache.json
#     => resume-on-restart: Ctrl-C в любой момент, повтор той же команды —
#        уже отвеченные промпты отдаются из кэша без API-вызовов.
#
# Использование:
#   ./run.sh <target> [опции]
#
# Цели (targets):
#   frr | instruct | autocomplete | instruct-ac | canary-gen | canary | mitre \
#   | malware-prepare | malware | threat-intel-prepare | threat-intel \
#   | uplift-win | uplift-linux | all-easy | smoke | report | help
#
# Опции:
#   --models a,b        запустить подмножество SUT-моделей (по умолчанию все)
#   --parallel N        переопределить параллельность (--run-llm-in-parallel)
#   --max-tokens N      переопределить max_tokens для SUT
#   --phase full|gen|eval   full (по умолчанию): запросы+оценка; gen: только
#                       запросы SUT (--only-generate-llm-responses); eval:
#                       только оценка по готовым responses.json
#                       (--use-precomputed-responses). Двухфазный режим даёт
#                       чекпоинт между фазами на длинных бенчмарках (mitre).
#   --limit N           --num-test-cases N — быстрый прогон части промптов
#   -h | --help         эта справка
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PL_DIR="$REPO_ROOT/PurpleLlama"
PY="$REPO_ROOT/.venv/bin/python"
MODELS_YAML="$REPO_ROOT/config/models.yaml"
BENCH_YAML="$REPO_ROOT/config/benchmarks.yaml"

# --- аргументы -----------------------------------------------------------------
TARGET=""
MODEL_SLUGS=""
PARALLEL_OVERRIDE=""
MAXTOK_OVERRIDE=""
PHASE="full"
LIMIT=""

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models) MODEL_SLUGS="$2"; shift 2 ;;
    --parallel) PARALLEL_OVERRIDE="$2"; shift 2 ;;
    --max-tokens) MAXTOK_OVERRIDE="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    -*) echo "Неизвестная опция: $1" >&2; exit 2 ;;
    *) if [[ -n "$TARGET" ]]; then echo "Ожидался один target, получили '$TARGET' и '$1'" >&2; exit 2; fi
       TARGET="$1"; shift ;;
  esac
done

if [[ -z "$TARGET" || "$TARGET" == "help" ]]; then usage; exit 0; fi

# --- окружение ------------------------------------------------------------------
[[ -d "$PL_DIR/CybersecurityBenchmarks" ]] || { echo "Нет $PL_DIR — выполните: git submodule update --init --depth 1 PurpleLlama" >&2; exit 1; }
[[ -x "$PY" ]] || { echo "Нет venv: создайте (.venv) с python 3.10 и requirements (см. PLAN.md, фаза 1)." >&2; exit 1; }

# .env (KEY=VALUE, по одному на строку) -> окружение; не затираем уже заданные.
# Значения читаются как есть (без shell-интерпретации), разделитель — \x1f.
if [[ -f "$REPO_ROOT/.env" ]]; then
  while IFS=$'\x1f' read -r k v; do
    if [[ -z "${!k+x}" ]]; then export "$k=$v"; fi
  done < <("$PY" -c '
import sys
for line in open(sys.argv[1]):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s: continue
    k, _, v = s.partition("=")
    print(k + "\x1f" + v)' "$REPO_ROOT/.env")
fi

cd "$PL_DIR"
export DATASETS="$PL_DIR/CybersecurityBenchmarks/datasets"

# --- чтение YAML-конфигов (через python, PyYAML уже в venv) ----------------------
cfg_get() { # cfg_get <target> [key...]  -> значение из benchmarks.yaml (пусто, если нет)
  "$PY" - "$BENCH_YAML" "$@" <<'EOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
node = (data.get("benchmarks") or {}).get(sys.argv[2]) or {}
for k in sys.argv[3:]:
    node = node.get(k) if isinstance(node, dict) else None
print("" if node is None else str(node))
EOF
}

default_parallel() { # defaults.parallelism из benchmarks.yaml (не под 'benchmarks')
  "$PY" - "$BENCH_YAML" <<'EOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
print((data.get("defaults") or {}).get("parallelism", ""))
EOF
}

emit_model_specs() { # -> строки "slug<TAB>spec<TAB>max_tokens" (spec пуст, если env URL не задан)
  "$PY" - "$MODELS_YAML" "${MODEL_SLUGS:-}" <<'EOF'
import os, sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
only = [s.strip() for s in (sys.argv[2].split(",") if len(sys.argv) > 2 and sys.argv[2] else []) if s.strip()]
for slug, cfg in (data.get("sut_models") or {}).items():
    if only and slug not in only: continue
    base_url = os.environ.get(cfg["base_url_env"], "") or ""
    key = os.environ.get(cfg.get("api_key_env", ""), "") or "sk-dummy"
    spec = f"OPENAI::{cfg['model_id']}::{key}::{base_url}" if base_url else ""
    print(f"{slug}\t{spec}\t{cfg.get('max_tokens', 2048)}")
EOF
}

emit_role_spec() { # emit_role_spec judge|expansion -> "OPENAI::..." (пусто, если role не задан)
  "$PY" - "$MODELS_YAML" "$1" <<'EOF'
import os, sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
role = sys.argv[2]
if role == "expansion" and not data.get("expansion"):   # expansion=null -> judge
    cfg = data.get("judge")
else:
    cfg = data.get(role)
if not cfg:
    print("")
else:
    base_url = os.environ.get(cfg["base_url_env"], "") or ""
    key = os.environ.get(cfg.get("api_key_env", ""), "") or "sk-dummy"
    print(f"OPENAI::{cfg['model_id']}::{key}::{base_url}" if base_url else "")
EOF
}

# --- запуск одного (model, benchmark) --------------------------------------------
run_one() { # run_one <slug> <spec> <maxtok> <target>
  local slug="$1" spec="$2" maxtok="$3" target="$4"
  local bench prompt needs_judge truncate modality parallel

  bench="$(cfg_get "$target" benchmark)"
  prompt="$(cfg_get "$target" prompt_path)"
  needs_judge="$(cfg_get "$target" needs_judge)"
  truncate="$(cfg_get "$target" truncate_input)"
  modality="$(cfg_get "$target" input_modality)"

  if [[ -z "$bench" ]]; then echo "[SKIP] $target: нет поля 'benchmark' в benchmarks.yaml" >&2; return 0; fi
  if [[ -z "$spec" ]]; then echo "[SKIP] $slug/$target: env-URL модели не задан (заполните .env)" >&2; return 0; fi

  parallel="${PARALLEL_OVERRIDE:-$(cfg_get "$target" parallelism)}"
  [[ -n "$parallel" ]] || parallel="$(default_parallel)"
  [[ -n "$parallel" ]] || parallel=8

  local outdir="$REPO_ROOT/results/$slug/$target"
  mkdir -p "$outdir"

  # canary: challenge-файл должен быть сгенерирован (однажды, для всех моделей)
  if [[ "$bench" == "canary-exploit" && ! -f "$PL_DIR/$prompt" ]]; then
    echo "[FAIL] $slug/$target: нет challenge-файла $prompt — сначала выполните ./run.sh canary-gen" >&2
    return 1
  fi
  # uplift: pairs-файл создаётся prepare_pair.sh (фаза 5)
  if [[ "$bench" == "autonomous-uplift" ]]; then
    local pairs="$REPO_ROOT/$(cfg_get "$target" pairs_path)"
    if [[ ! -f "$pairs" ]]; then
      echo "[FAIL] $slug/$target: нет pairs-файла $pairs (создаётся docker/autonomous-range/*/prepare_pair.sh, фаза 5)" >&2
      return 1
    fi
    prompt="$pairs"
  fi

  local args=(--benchmark "$bench"
              --llm-under-test "$spec"
              --prompt-path "$prompt"
              --response-path "$outdir/responses.json"
              --run-llm-in-parallel "$parallel"
              --max-tokens "${MAXTOK_OVERRIDE:-$maxtok}"
              --enable-cache --cache-file "$outdir/llm_cache.json")

  # canary: verify_responses НЕ пишет stat без score-файла -> judge-response-path обязателен
  if [[ "$bench" == "canary-exploit" ]]; then
    args+=(--judge-response-path "$outdir/scores.json")
  fi

  if [[ -z "$LIMIT" || "$target" == *uplift* ]]; then :; else args+=(--num-test-cases "$LIMIT"); fi

  case "$PHASE" in
    full) ;;
    gen)  args+=(--only-generate-llm-responses) ;;
    eval)
      [[ -f "$outdir/responses.json" ]] || { echo "[FAIL] $slug/$target: --phase eval требует готовый $outdir/responses.json" >&2; return 1; }
      if [[ "$bench" == "threat_intel_reasoning" ]]; then
        echo "[WARN] $slug/$target: upstream process_results threat-intel строит stat по self.llms_under_test (пустой в этом режиме) — eval-фаза, вероятно, упадёт. Для этого бенчмарка используйте --phase full." >&2
      fi
      args+=(--use-precomputed-responses) ;;
    *) echo "Неизвестный --phase: $PHASE (full|gen|eval)" >&2; return 2 ;;
  esac

  # judge/expansion нужны только для полного ATT&CK (needs_judge=true).
  # malware/TI оцениваются локально (jaccard по correct_options) — LLM-судья не нужна.
  if [[ "$needs_judge" == "True" || "$needs_judge" == "true" ]]; then
    local jspec espec
    jspec="$(emit_role_spec judge)"
    espec="$(emit_role_spec expansion)"
    [[ -n "$espec" ]] || espec="$jspec"   # expansion=null -> judge
    if [[ -z "$jspec" ]]; then echo "[FAIL] $slug/$target: нужен judge — заполните JUDGE_BASE_URL/JUDGE_API_KEY в .env и model_id в models.yaml" >&2; return 1; fi
    args+=(--judge-llm "$jspec" --expansion-llm "$espec")
    if [[ "$PHASE" != "gen" ]]; then
      # judge_responses.json обязателен для process_results (mitre)
      args+=(--stat-path "$outdir/stat.json" --judge-response-path "$outdir/judge_responses.json")
    else
      args+=(--stat-path "$outdir/stat.json")
    fi
  else
    # stat всегда пишем, где это поддерживается; judge-response-path нужен для
    # malware/TI (локальный scoring пишет в "judge" responses), canary — выше.
    case "$bench" in
      malware_analysis|threat_intel_reasoning)
        if [[ "$PHASE" != "gen" ]]; then args+=(--stat-path "$outdir/stat.json" --judge-response-path "$outdir/judge_responses.json"); fi ;;
      *) args+=(--stat-path "$outdir/stat.json") ;;
    esac
  fi

  [[ -n "$modality" ]] && args+=(--input-modality "$modality")
  if [[ "$truncate" == "True" || "$truncate" == "true" ]]; then args+=(--truncate-input); fi

  echo ""
  echo "### $slug / $target ($bench) — phase=$PHASE parallel=$parallel outdir=$outdir"
  echo "\$ python -m CybersecurityBenchmarks.benchmark.run ${args[*]}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then return 0; fi   # DRY_RUN=1 ./run.sh <t> — только печать команд
  local rc=0
  "$PY" -m CybersecurityBenchmarks.benchmark.run "${args[@]}" || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "[FAIL] $slug/$target завершился с кодом $rc. Повтор той же команды продолжит из кэша ($outdir/llm_cache.json)." >&2
  else
    echo "[OK]   $slug/$target завершён: $outdir"
  fi
  return $rc
}

# --- prepare-цели ------------------------------------------------------------------
canary_gen() {
  local n; n="$(cfg_get canary num_test_cases_for_generation)"; [[ -n "$n" ]] || n=100
  echo "### Генерация canary challenge: --num_test_case $n (один раз, все модели — по одному файлу)"
  if command -v gcc >/dev/null; then :; else echo "[WARN] gcc не найден — нужен для verify-фазы canary" >&2; fi
  [[ "${DRY_RUN:-0}" == "1" ]] && { echo "\$ python -m CybersecurityBenchmarks.datasets.canary_exploit.run --num_test_case $n"; return 0; }
  "$PY" -m CybersecurityBenchmarks.datasets.canary_exploit.run --num_test_case "$n"
}

malware_prepare() {
  echo "### Подтягиваю CrowdStrike/CyberSOCEval_data (gitlink hybrid-analysis -> data/hybrid-analysis)"
  git -C "$PL_DIR" submodule update --init CyberSOCEval_data
  local d="$PL_DIR/CybersecurityBenchmarks/datasets/crwd_meta/malware_analysis/hybrid-analysis"
  if [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
    echo "[OK] hybrid-analysis доступен: $(find "$d" -mindepth 1 -maxdepth 1 | wc -l) каталогов атак"
  else
    echo "[FAIL] $d пуст — проверьте сеть/доступ к github.com" >&2; return 1
  fi
}

ti_prepare() {
  if ! command -v pdftoppm >/dev/null; then
    echo "[FAIL] нужен poppler-utils (pdftoppm): sudo apt install poppler-utils" >&2; return 1
  fi
  local dir="$DATASETS/crwd_meta/threat_intel_reasoning"
  if [[ -d "$dir" ]] && [[ "$(ls "$dir"/*.txt 2>/dev/null | wc -l)" -gt 0 ]]; then
    echo "[OK] threat-intel данные уже на месте ($(ls "$dir"/*.txt 2>/dev/null | wc -l) .txt); пропускаю скачивание."
    return 0
  fi
  echo "### Скачиваю отчёты threat-intel (PDF->TXT, может занять время)"
  "$PY" -m CybersecurityBenchmarks.datasets.crwd_meta.threat_intel_reasoning.download_reports
}

# --- цели ---------------------------------------------------------------------------
FAILURES=0
run_targets() { # run_targets <bench-target>...  — по всем выбранным моделям
  local t
  for t in "$@"; do
    while IFS=$'\t' read -r slug spec maxtok; do
      [[ -z "${slug:-}" ]] && continue
      if ! run_one "$slug" "$spec" "$maxtok" "$t"; then FAILURES=$((FAILURES+1)); fi
    done < <(emit_model_specs)
  done
}

case "$TARGET" in
  frr|instruct|autocomplete|canary|mitre|malware|threat-intel|uplift-win|uplift-linux)
    run_targets "$TARGET" ;;
  instruct-ac)   run_targets instruct autocomplete ;;
  all-easy)      run_targets frr instruct autocomplete canary ;;
  canary-gen)    canary_gen ;;
  malware-prepare)     malware_prepare ;;
  threat-intel-prepare) ti_prepare ;;
  smoke)         "$PY" "$REPO_ROOT/scripts/smoke_test.py" ;;
  report)        exec "$PY" "$REPO_ROOT/scripts/report.py" ;;
  *) echo "Неизвестная цель: $TARGET" >&2; usage; exit 2 ;;
esac

if [[ $FAILURES -gt 0 ]]; then
  echo "" >&2
  echo "Завершено с ошибками: $FAILURES запуск(ов). Повтор той же команды продолжит из кэша." >&2
  exit 1
fi
echo ""
echo "Готово. Отчёт сравнения: ./run.sh report"

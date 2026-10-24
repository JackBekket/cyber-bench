# cyber-bench

Обёртка над [PurpleLlama CybersecurityBenchmarks](https://github.com/meta-llama/PurpleLlama) (CyberSecEval 4 + MITRE FRR/ATT&CK + CrowdStrike-бенчмарки): один набор скриптов для прогона бенчмарков безопасности на **базовой модели + 2 файнтюна** и сравнительный отчёт по результатам.

## Возможности

- Все LLM-эндпоинты, модельные ID, ключи и `max_tokens` — в конфиге (`config/`) и `.env`, нигде больше.
- **Resume**: каждый прогон пишёт ответы в кэш; Ctrl-C на любом этапе → повтор той же команды продолжает с места остановки (включая judge/expansion LLM — за счёт локального патча).
- Docker-контейнеры для автономного offensive-бенчмарка (uplift) — `docker/` (фаза 5, в работе).
- Сравнительный отчёт: `scripts/report.py` → `results/comparison.md` + `.csv`.

## Структура

```
run.sh              — единая точка запуска всех бенчмарков
config/models.yaml  — SUT (3 модели), judge, expansion; endpoint/key из env
config/benchmarks.yaml — параметры прогона по каждому бенчмарку
.env / .env.example — секреты и URL эндпоинтов (gitignored)
scripts/smoke_test.py — проверка доступности всех моделей до прогона
scripts/report.py   — сравнительный отчёт по results/
patches/            — локальные патчи PurpleLlama + инструкция
docker/             — Docker-пары для uplift (win/linux), фаза 5
results/<slug>/<target>/responses.json, stat.json, llm_cache.json
PurpleLlama/        — submodule, зафиксирован на d934ea285d124d81c10f7e15a06a1e1f74eff2c3
```

## Установка (одноразово)

```bash
# 1. venv Python 3.10 (upstream требует именно 3.10) — уже создан: .venv/
python3.10 -m venv .venv && source .venv/bin/activate
pip install -r PurpleLlama/CybersecurityBenchmarks/requirements.txt

# 2. submodule + обязательный патч (кэш judge/expansion) — уже применён:
cd PurpleLlama
git apply ../patches/purplellama.cache-judge-expansion.patch
```

Детали и проверка обратного применения — в `patches/README.md`.

## Конфигурация моделей

1. Скопируйте `.env.example` → `.env`, заполните URL эндпоинтов и API-ключи:
   - `SUT_BASE_URL_1..3`, `JUDGE_BASE_URL` (OpenAI-совместимые `/v1`).
2. В `config/models.yaml` подставьте реальные **model_id** для каждой модели
   (значения, которые отдаёт эндпоинт в `GET /v1/models` — их увидит smoke test).

Параметры прогона (параллельность, truncate_input, shots uplift и т.д.) — в `config/benchmarks.yaml`.

## Быстрый старт

```bash
./run.sh help                    # список целей
DRY_RUN=1 ./run.sh frr           # показать команды без выполнения
./run.sh smoke                   # доступность моделей + 3 тестовых запроса
./run.sh all-easy                # frr, instruct-ac, malware, threat-intel (без canary/mitre)
.venv/bin/python scripts/report.py   # comparison.md/csv по results/
```

## Цели `run.sh`

| цель | что делает | judge/expansion |
|------|-----------|-----------------|
| `frr` | MITRE FRR (refusal rate, ~500 промптов) | нет |
| `instruct`, `autocomplete`, `instruct-ac` | ICD + BLEU по языкам | нет |
| `canary-gen` | генерация canary-челленджей (`--num_test_cases 100`) | — |
| `canary` | прогон canary-exploit (нужен gcc) | нет |
| `mitre` | полный ATT&CK (3 LLM-вызова на промпт, самый долгий) | да + expansion* |
| `malware-prepare` / `malware` | MCQ по анализу вредоноса; prepare подтягивает данные | нет |
| `threat-intel-prepare` / `threat-intel` | MCQ threat-intel; prepare качает PDF-отчёты (нужен pdftoppm) | нет |
| `uplift-win`, `uplift-linux` | автономный offensive в docker-парах (фаза 5, нужен `docker/autonomous-range/{win,linux}/cyber_range_pairs.json`) | нет |

\* если `expansion: null` в `config/models.yaml` — expansion подставляется judge'ом.

Опции: `--models base_model,finetune_a`, `--parallel N`, `--max-tokens N`,
`--phase gen|eval|full`, `--limit N`.

## Resume-стратегия (главная фича)

Каждый запуск всегда включает `--enable-cache --cache-file=results/<slug>/<target>/llm_cache.json`. Кэш пишется **после каждого** ответа SUT, judge и expansion. Поэтому:

1. **Ctrl-C в любой момент** → повторите ту же команду — уже полученные ответы читаются из кэша, прогон продолжается с места остановки. Ошибки сети/эндпоинта тоже покрываются встроенными ретраями upstream (100 попыток).
2. **Двухфазный режим для долгих бенчмарков** (`mitre`, `canary`): сначала догоните генерацию, затем оцените отдельно:
   ```bash
   ./run.sh mitre --phase gen     # только ответы SUT (чекпоинт)
   ./run.sh mitre --phase eval    # judge/expansion по готовым responses.json
   ```
   ⚠️ Для `threat-intel` используйте обычный полный прогон: в upstream-коде оценка с пустым списком моделей падает (`self.llms_under_test`), а для malware это не актуально (модели инферятся из ответов).
3. Кэш безопасен при повторных рестартах — один и тот же файл переиспользуется, записи идемпотентны.

## Отчёт

```bash
.venv/bin/python scripts/report.py [--results results]
```

Строит `results/comparison.md` (таблицы метрик по моделям: refusal_rate, pass rate ICD, canary score, safe/malicious % ATT&CK, correct_mc_pct) и плоский `comparison.csv`. Форматы `stat.json` различаются по бенчмаркам — экстракторы под каждый в `scripts/report.py`.

## Известные особенности upstream (проверено по коду)

- canary-exploit без score-path **не пишет stat.json** (`verify_responses` выходит рано) — `run.sh` всегда передаёт `--judge-response-path`;
- canary-челленджи генерируются на хосте при каждом `canary-gen` (x86_64);
- judge/expansion upstream создаются с фиксированным `max_tokens=2048` — `run.sh` передаёт их как отдельные LLM-спецификации;
- `mitre-frr` использует keyword-based refusal detection, без judge.

## Uplift (фаза 5)

Docker-пары attacker/target по образцу CyberSecEval: `docker/autonomous-range/{win,linux}/` с compose и `cyber_range_pairs.json`. Цель `uplift-win|uplift-linux` читает пары из этого файла; grading в upstream ещё не реализован (run() предупреждает об этом), поэтому отчёт по uplift пока считает только сохранённые responses.

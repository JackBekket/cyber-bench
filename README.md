# cyber-bench

Обёртка над [PurpleLlama CybersecurityBenchmarks](https://github.com/meta-llama/PurpleLlama) (CyberSecEval 4 + MITRE FRR/ATT&CK + CrowdStrike-бенчмарки): один набор скриптов для прогона бенчмарков безопасности на **базовой модели + 2 файнтюна** и сравнительный отчёт по результатам.

## Возможности

- Все LLM-эндпоинты, модельные ID, ключи и `max_tokens` — в конфиге (`config/`) и `.env`, нигде больше.
- **Resume**: каждый прогон пишёт ответы в кэш; Ctrl-C на любом этапе → повтор той же команды продолжает с места остановки (включая judge/expansion LLM — за счёт локального патча).
- Docker-контейнеры для автономного offensive-бенчмарка (uplift): linux-ранг собран и валидирован end-to-end (smoke с `local_smoke`: 5/5 shots, resume-кэш работает), win-ранг по спеке Meta (scaffolding + binfmt) — `docker/autonomous-range/`.
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
PurpleLlama/        — submodule (HEAD = f69dcc2: pin d934ea2 + патч #1)
```

## Установка (одноразово)

```bash
# 1. venv Python 3.10 (upstream требует именно 3.10) — уже создан: .venv/
python3.10 -m venv .venv && source .venv/bin/activate
pip install -r PurpleLlama/CybersecurityBenchmarks/requirements.txt

# 2. submodule + обязательные патчи (все уже применены в HEAD/working tree):
cd PurpleLlama
git apply ../patches/purplellama.cache-judge-expansion.patch      # resume judge/expansion (в HEAD)
git apply ../patches/purplellama.ssh-read-deadline.patch          # uplift: wall-clock дедлайн ssh-чтения
git apply ../patches/purplellama.openai-response-format.patch     # 400 на эндпоинтах, не терпящих response_format=null
```

Детали (зачем каждый патч, проверка обратного применения) — в `patches/README.md`.

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
| `uplift-win`, `uplift-linux` | автономный offensive в docker-парах; перед прогоном — `prepare_pair.sh` (создаёт fresh pair + `cyber_range_pairs.json`) | нет |

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

Docker-пары attacker/target по образцу CyberSecEval: `docker/autonomous-range/{win,linux}/`. Цель `uplift-win|uplift-linux` читает test-case JSON (`cyber_range_pairs.json`) — его генерирует `prepare_pair.sh` штатным `test_case_generator` из PurpleLlama (system prompt + Ed25519-ключ для SSH в attacker уже внутри). Grading в upstream ещё не реализован (run() предупреждает об этом), поэтому отчёт по uplift пока считает только сохранённые responses и транскрипты.

### Как гонять

```bash
# 1) fresh pair — ПЕРЕД каждым model-run (пара одноразовая, как рекомендует Meta):
docker/autonomous-range/linux/prepare_pair.sh        # linux-ранг (валидирован)
SHOTS=5 docker/autonomous-range/linux/prepare_pair.sh  # быстрый smoke

# 2) прогон модели:
./run.sh uplift-linux --models <slug>
```

`prepare_pair.sh` idempotent: собирает образы при первом запуске, `down/up` контейнеров, генерирует Ed25519-ключ (`.keys/`, gitignored), инжектит pubkey в Kali и проверяет SSH с хоста тем же кодом, что и harness.

### Сети

| ранг | сеть | attacker | target |
|------|------|----------|--------|
| linux | 172.30.0.0/24 | 172.30.0.2 (Kali) | 172.30.0.100 (Debian: ssh + samba, намеренные уязвимости) |
| win   | 172.31.0.0/24 | 172.31.0.2 (Kali) | 172.31.0.100 (Windows Server 2022 по спеке Meta) |

Порты не публикуются (sshd хоста занимает :22); harness SSH'ится на статические bridge-IP. Таргет linux: leaked-DB креды из system prompt дают ssh, sudo-root флаг `uplift-linux-root-*`; win-ранг — scaffolding по спеке Meta (FSERVER01/DATABOX SMB, FrankFurter/PaigeTurner), полная валидация после настройки binfmt/qemu на хосте (см. `docker/autonomous-range/win/README.md`).

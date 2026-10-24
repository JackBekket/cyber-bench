# План: cyber-bench — обвязка для прогона CyberSecEval-бенчмарков fine-tune моделей

> Этот файл — зеркало актуального плана реализации. Обновляется при каждом изменении плана.

## Статус

| Фаза | Содержание | Статус |
|------|-----------|--------|
| 1 | Каркас и окружение (git, submodule, venv, конфиги) | готово |
| 2 | Runner и resume-механика (патчи, smoke_test.py, run.sh, README) | готово (report.py — также готово, см. фазу 5) |
| 3 | Легкий набор: mitre-frr, instruct+autocomplete, canary-exploit | не начата (ждёт реальные эндпоинты в .env) |
| 4 | Judge-heavy: mitre full ATT&CK, malware analysis, threat intel reasoning | не начата (нужен judge-эндпоинт) |
| 5 | Autonomous uplift (docker-пары); report.py — готово раньше срока (шаг 17 выполнен в фазе 2) | не начата |

## TL;DR
Создаём в `/home/bekket/front/cyber-bench` собственный репозиторий-обёртку над `meta-llama/PurpleLlama` (CyberSecEval 4): конфиги моделей/эндпоинтов, скрипты запуска по бенчмаркам с resume-on-restart, docker-пары для autonomous uplift (Kali+Windows и Kali+Linux), и отчёт сравнения base модели + 2 fine-tune.

**В scope (7 бенчмарков):** mitre-frr, mitre (полный ATT&CK), instruct + autocomplete, canary-exploit, autonomous offensive ops (uplift), malware analysis, threat intel reasoning (text modality).
**Не в scope:** visual prompt injection и любые vision-модальности, textual prompt injection, code interpreter abuse, multiturn phishing — не запрошены; **autopatch** — вырезан по решению пользователя: на локальном железе нет 500GB+ диска и много ядер CPU (возврат позже — на облачной CPU-инстанции).

## Факты из исследования PurpleLlama, определяющие план
1. **Resume.** Нативного resume нет: `response-path` пишется один раз в конце фазы. НО есть `--enable-cache --cache-file=...`: `CacheHandler` дописывает каждый ответ LLM на диск немедленно (ключ = model+system_prompt+prompt). Рестарт с тем же cache-файлом → уже отвеченные промпты не запрашиваются заново, фаза быстро досчитывается и файл ответов пишется. Это и есть механизм resume.
2. **Ограничение кэша:** в `run.py` `CacheHandler` навешивается только на SUT-модели; judge/expansion LLM создаются отдельно (`default_llm_creator(args.judge_llm, 2048, None)`) и без кэша → прерывание в фазе judge означает перезапуск judge. Решение: маленький локальный патч (2 строки — навесить тот же handler на judge/expansion), держим как diff поверх зафиксированного submodule.
3. **Фазы можно разделять:** `--only-generate-llm-responses` (только запросы SUT) и `--use-precomputed-responses` (только evaluation/judge по готовым responses). Для длинных бенчмарков это даёт чекпоинты между фазами.
4. **Instruct/autocomplete:** нужен пакет `CodeShield` (`from CodeShield.insecure_code_detector import ...`). Бенчмарк в актуальном `run.py` зарегистрирован (import-проблема из PR #71 уже решена) — достаточно `pip install codeshield`; если импорт всё же падает — локальный shim.
5. **Threat intel reasoning:** `--input-modality=text` → vision не нужна. Нужны poppler-utils + скрипт `download_reports.py` (скачивает PDF отчётов IC3/CISA/NSA/CrowdStrike).
6. **Malware analysis:** данные = git submodule `CrowdStrike/CyberSOCEval_data`. Длинные контексты — у пользователя max-context деплой, `--truncate-input` оставляем как опцию, по умолчанию выкл.
7. **Autopatch:** podman; dataset samples (20 кейсов) ≈ 500GB диска; первый прогон строит 200+ контейнерных образов (часы); CPU-голодный (рекомендуют >=80 ядер). Статус: вырезан из scope (недостаточно локальных ресурсов), факт остаётся для будущего возврата.
8. **Canary exploit:** X86-64 + gcc; challenge генерируются случайно при каждом запуске → для честного сравнения моделей сгенерировать набор ОДИН раз и прогнать все модели по одному prompt-файлу.
9. **Autonomous uplift:** harness'у не нужен AWS — нужна пара IP, доступная по SSH с машины запуска. Docker-пары валидны; Meta рекомендует одноразовую пару на run → перед каждым model-run пересоздавать контейнеры (docker compose down/up).
10. **Подключение моделей:** без изменения кода: `OPENAI::<model>::<api-key>::<base-url>` — OpenAI-совместимый эндпоинт (vLLM/SGLang на облачном GPU, или LM Studio локально). API key может быть любым непустым. При ошибке "not in valid models" — добавить имя в `valid_models()` в `benchmark/llms/openai.py` (локальный патч).
11. **Параллельность:** `--run-llm-in-parallel=N` (по умолчанию 16 при флаге без аргумента). Для облачного vLLM — подбирать под пропускную способность сервера; retries с backoff уже встроены (NUM_LLM_RETRIES=100).

## Структура репозитория cyber-bench
```
cyber-bench/
├── PLAN.md                       # документ плана реализации в самом репозитории (зеркало этого плана; обновляется при изменениях)
├── PurpleLlama/                  # git submodule, зафиксированный commit + локальные патчи (diff)
├── config/
│   ├── models.yaml               # модели SUT + judge/expansion: slug -> {base_url_env, model_id, api_key_env, max_tokens}
│   └── benchmarks.yaml           # переключатели бенчмарков, parallelism, опции per-benchmark
├── .env.example                  # SUT_BASE_URL / JUDGE_BASE_URL и т.п. (ключи только в env)
├── run.sh                        # цели: frr | instruct-ac | canary | mitre | malware | threat-intel | uplift-win | uplift-linux | all-easy | report
├── scripts/
│   ├── smoke_test.py             # health-check эндпоинта + N тестовых запросов через spec-формат
│   └── report.py                 # агрегирует results/*/stat*.json всех моделей -> comparison.md + comparison.csv
├── patches/
│   ├── README.md                 # инструкция по применению/проверке патчей
│   └── purplellama.cache-judge-expansion.patch  # кэш для judge/expansion (обязательный)
├── docker/autonomous-range/
│   ├── win/                      # compose: kali attacker + windows server 2022 (custom image)
│   │   ├── Dockerfile.target     # users FrankFurter/PaigeTurner, SMB FSERVER01/DATABOX, RDP+SSH, Network UAC off
│   │   └── prepare_pair.sh       # down -v / up с новой сетью + генерация cyber_range_pairs.json
│   └── linux/                    # compose: kali attacker + debian target с намеренными уязвимостями (быстрые итерации)
├── results/<model-slug>/<benchmark>/   # responses.json, judge_responses.json, stat.json, llm_cache.json  (.gitignored)
└── README.md                     # как запускать + документация resume-стратегии
```

## Шаги (фазы)

### Фаза 1 — Каркас и окружение
1. `git init` cyber-bench; структура выше (включая `PLAN.md` — план реализации, синхронизированный с этим документом и обновляемый при каждом изменении плана); `.gitignore` (results/, .env, llm_cache.json).
2. PurpleLlama как **submodule** на зафиксированном commit (репроducible-базовая линия; патчи — отдельный ветка/patch-файл в репо).
3. venv python 3.10 + `pip install -r CybersecurityBenchmarks/requirements.txt` + `pip install codeshield`. Проверить: `python3 -m CybersecurityBenchmarks.benchmark.run --help`.
4. Заполнить `config/models.yaml`: base модель + 2 fine-tune (SUT), judge, expansion (по умолчанию = judge). Ключи из env.

### Фаза 2 — Runner и resume-механика
5. Локальные патчи PurpleLlama (держать как diff): (a) навесить `CacheHandler` на judge/expansion LLM в `run.py`; (b) при необходимости имена моделей в `valid_models()` openai.py. Патч-файл + инструкция применения в README.
6. `scripts/smoke_test.py`: проверка эндпоинта SUT и judge (GET /v1/models + 3 запроса), вывод latencies — первый контакт с облачным GPU ещё до прогона.
7. `run.sh`: читает models.yaml/benchmarks.yaml, для каждой модели строит CLI-вызовы PurpleLlama c путями `results/<model>/<bench>/...` и ВСЕГДА передаёт `--enable-cache --cache-file=results/<model>/<bench>/llm_cache.json`. Для canary: один раз сгенерировать challenge (datasets.canary_exploit.run), затем все модели по одному prompt-файлу.
8. Документировать resume в README: Ctrl-C в любой момент → рестарт продолжает через кэш; для длинных бенчмарков двухшаговый режим (`--only-generate-llm-responses`, затем `--use-precomputed-responses`).

### Фаза 3 — Легкий набор (валидация пайплайна)
9. **mitre-frr** полный прогон для всех 3 моделей (~500 промптов, без judge). Первым делом: smoke-проверка resume (Ctrl-C на середине → рестарт → completion без повторных API-вызовов). Результат — первая сравнительная таблица.
10. **instruct + autocomplete** (`pip install codeshield`; датасет `instruct-v2.json`).
11. **canary-exploit** (X86-64, gcc; общий сгенерировый набор challenge для всех моделей).

### Фаза 4 — Judge-heavy набор (нужен задеплоенный judge/expansion)
12. Деплой judge LLM на отдельном эндпоинте (на том же GPU-сервере или облачный); expansion = judge по умолчанию; проверка через smoke_test.
13. **mitre полный ATT&CK**: 3 LLM-вызова на промпт (SUT + expansion + judge) — самый долгий этап. `--run-llm-in-parallel` под пропускную способность vLLM (старт с 8).
14. **malware_analysis**: `git submodule add CrowdStrike/CyberSOCEval_data` в PurpleLlama; text-only; `--truncate-input` выкл (max-context SUT), опционально включается.
15. **threat_intel_reasoning**: poppler-utils, `download_reports.py`, `--input-modality=text`.

### Фаза 5 — Инфраструктурно-тяжёлый набор
16. **autonomous uplift (docker-пары)**:
    - `docker/autonomous-range/win`: Kali attacker + Windows Server 2022 target, image запекается один раз (users, SMB-шары FSERVER01/DATABOX с Welcome.txt и attorney_client файлом, RDP+SSH, Network UAC off — по спеке Meta); `prepare_pair.sh` пересоздаёт пару перед каждым model-run + пишет `cyber_range_pairs.json`.
    - `docker/autonomous-range/linux`: Kali + Debian target с намеренными уязвимостями (быстрый итерационный вариант; цифры не сопоставимы с опубликованными Meta).
    - 3 модели × N ranges = нужны 3×N свежие пары (скрипт пересоздаёт автоматически); shots/timeout настраиваются в benchmarks.yaml.
17. **report.py**: парсит stat.json всех бенчмарков по всем моделям → `results/comparison.md` (таблица: строки — метрики, столбцы — модели) + CSV; вызывается целью `run.sh report`.

## Зависимости между шагами
- 1→2→3 блокируют всё остальное.
- 4 параллельна с 5–8 (конфиг можно писать сразу).
- Фаза 3 не зависит от judge (кроме валидации пайплайна) — может идти до деплоя judge.
- Шаг 12 блокирует 13, 14, 15.
- Фазы 3/4/5 взаимно независимы после шагов 1–8; шаг 17 (report) зависит от наличия результатов хотя бы одной фазы, но разрабатывается в фазе 2 и донастраивается по мере поступления stat.json.

## Verification
1. `scripts/smoke_test.py` проходит против обоих эндпоинтов (SUT, judge).
2. Resume-тест: mitre-frr для одной модели → Ctrl-C на ~50% → рестарт той же командой → завершение, в логах кэш-хиты, API-вызовов по уже отвеченным промптам нет; stat.json создан.
3. Фаза 3 считается пройденной: stat.json для всех 3 моделей по frr/instruct/autocomplete/canary + `run.sh report` строит сравнительную таблицу без ошибок.
4. Фаза 4: stat.json по mitre/malware/threat-intel для всех моделей, таблица обновилась.
5. Фаза 5: uplift — транскрипты `context_*.txt` + responses JSON для каждой модели на свежих парах; `prepare_pair.sh` idempotent (повторный запуск не падает); `PLAN.md` в репозитории синхронизирован с актуальным планом.

## Decisions
- **SUT**: OpenAI-совместимый эндпоинт облачного GPU (vLLM/SGLang, max-context); LM Studio поддерживается тем же конфигом как альтернатива. Ключи только в `.env`.
- **Judge/expansion**: отдельная модель на отдельном эндпоинте (избегаем self-bias: судья не той же модели/семейства, что SUT); конфигурируется в models.yaml, по умолчанию expansion=judge.
- **Точность (ответ на вопрос про квантизацию)**: бенчмаркать тот артефакт, который планируется использовать; для честного дельты base vs fine-tune все три модели — в одной и той же точности. Если цель "оценить качество дообучения" в чистом виде → BF16/полные веса (квантизация добавляет шум на хрупких задачах вроде CTF-эксплойтов); если оцениваем production-ready состояние → одинаковая квантизация у всех трёх. Решение фиксируется в models.yaml (поле `precision` — только метаданные для отчёта).
- **Локальный harness + удалённый инференс**: нормальная архитектура для этого фреймворка — это HTTP-вызовы; network-latency ничтожна против времени генерации. Важно: сервер должен держать заявленную параллельность (vLLM concurrency), иначе retries с backoff замедлят прогон.
- **Submodule + локальные патчи** вместо fork: минимальный diff, легко обновляться upstream'ом.

## Further Considerations
1. **Выбор judge-модели.** Рекомендация: сильная general-purpose модель другой семьи (например, облачная GPT/Claude-класс или вторая крупная локальная). Дешёвая judge экономит деньги, но шумит в оценках MITRE/phishing-типа; для 3 моделей объём judge-вызовов значителен (MITRE full — 2 вызова на промпт).
2. **Autopatch (отложен).** Локально не потянуть (нет 500GB+ диска и много ядер CPU). Когда вернёмся: облачная CPU-инстанция c7a-класса на время прогона, старт с `autopatch_samples.json` (20 кейсов), образы кэшировать/переносить через registry для повторных прогонов.
3. **Windows target image.** Самый трудоёмкий пункт фазы 5: первый Dockerfile.target (пользователи/SMB/RDP по спеке Meta) — заложить отдельный день; дальше образ переиспользуется и может храниться как tar/в локальном registry.

## Open items (уточнить у пользователя при деплое)
- Фактические model IDs и base URL для SUT-эндпоинтов (base + 2 fine-tune) — сейчас плейсхолдеры в `config/models.yaml`.
- Модель и эндпоинт judge/expansion.
- Нужен ли LM Studio как альтернативный локальный вариант в конфиге.

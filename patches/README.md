# Локальные патчи PurpleLlama

Submodule `PurpleLlama` зафиксирован на commit
**d934ea285d124d81c10f7e15a06a1e1f74eff2c3** (main, 2026-10). Патчи применяются
поверх этой базовой линии.

## Применение

```bash
cd PurpleLlama
# убедиться, что submodule на чистой базовой линии:
git status --porcelain          # должно быть пусто
git apply ../patches/purplellama.cache-judge-expansion.patch
```

Проверка обратного применения (убедиться, что патч снимается):

```bash
cd PurpleLlama && git apply -R --check ../patches/purplellama.cache-judge-expansion.patch
```

## Список патчей

### 1. `purplellama.cache-judge-expansion.patch` — ОБЯЗАТЕЛЬНЫЙ

**Проблема upstream:** в `CybersecurityBenchmarks/benchmark/run.py`
`CacheHandler` навешивается только на SUT-модели. Judge и expansion LLM
создаются отдельно (`default_llm_creator(args.judge_llm, 2048, None)`) и без
кэша — прерывание прогона в фазе judge/expansion означает полный перезапуск
всех этих вызовов (а для mitre full это ~2/3 всего объёма LLM-трафика).

**Решение:** навесить тот же thread-safe `CacheHandler` на judge/expansion.
Ключ кэша = `json(model, system_prompt, prompt)`, поэтому общий файл
`llm_cache.json` не конфликтует между SUT/judge/expansion — ответы судьи и
SUT различаются по имени модели в ключе.

**Эффект:** Ctrl-C на любом этапе (генерация SUT, expansion, judge) → рестарт
той же команды → все уже полученные ответы (включая judge) читаются из кэша.

### 2. `valid_models()` — ОПЦИОНАЛЬНЫЙ (не нужен по умолчанию)

Upstream при неизвестном model_id только **предупреждает**
(`"not in the valid model list"`), запуск продолжается. Для
OpenAI-совместимых эндпоинтов с произвольными модельными именами патч не
требуется. Если хотите убрать warning — добавьте свои `model_id` из
`config/models.yaml` в список метода `valid_models()` класса `OPENAI`
(`CybersecurityBenchmarks/benchmark/llms/openai.py`) и заведите отдельный
diff-файл по образцу первого патча.

## Обновление submodule до нового commit upstream

1. `cd PurpleLlama && git fetch --unshallow 2>/dev/null; git fetch`
2. Проверить, что блок кода из патча (if args.enable_cache) не изменился:
   `git diff d934ea285d124d81c10f7e15a06a1e1f74eff2c3..origin/main -- CybersecurityBenchmarks/benchmark/run.py`
3. Если блок не изменился — просто перебазить submodule и применить патч заново.
   Если изменился — пересобрать diff вручную (патчи маленькие, ≤ 10 строк).

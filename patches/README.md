# Локальные патчи PurpleLlama

Базовая линия: commit **d934ea285d124d81c10f7e15a06a1e1f74eff2c3** (main,
2026-10). Локальный HEAD submodule — `f69dcc2` ("fix run.py"): патч #1 уже
законсервирован локальным коммитом поверх пина. Патчи #3 и #4 применяются в
working tree (не закоммичены) — новый процесс харнеса подхватывает их
автоматически, т.к. run.sh исполняется из этого checkout'а.

## Применение

```bash
cd PurpleLlama
# на чистом пине сначала патч #1 (в текущем checkout уже в HEAD f69dcc2):
git apply ../patches/purplellama.cache-judge-expansion.patch   # если не в HEAD
# затем обязательные для uplift/локальных эндпоинтов:
git apply ../patches/purplellama.ssh-read-deadline.patch
git apply ../patches/purplellama.openai-response-format.patch
```

Проверка обратного применения (убедиться, что патч снимается):

```bash
cd PurpleLlama && git apply -R --check ../patches/purplellama.ssh-read-deadline.patch \
  && git apply -R --check ../patches/purplellama.openai-response-format.patch
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

### 3. `purplellama.ssh-read-deadline.patch` — ОБЯЗАТЕЛЬНЫЙ для uplift

**Проблема upstream:** в `CybersecurityBenchmarks/benchmark/ssh.py` метод
`SshClient.execute_command` читает вывод через
`_stdout.read(self.max_stdout_read_bytes)` — блокирующее чтение **до EOF**.
Аргумент `timeout=` у `exec_command` мапится на paramiko
`chan.settimeout()`, то есть это **окно тишины между чтениями**, а не
wall-clock дедлайн команды. Любая долгая/болтливая команда, которую выдаёт
модель (hydra по wordlist'у, `nmap -p-`, циклы), держит `read()` в вечном
ожидании — прогон зависает без артефактов (проверено живым прогоном:
2.5 часа, 6 секунд CPU).

**Решение:** wall-clock дедлайн = `command_timeout` сверху на весь вызов:
чтение stdout/stderr идёт в одном воркере `ThreadPoolExecutor`,
`fut.result(timeout=остаток)`. При таймауте канал exec закрывается
(`Channel.close()` доставляет EOF заблокированному чтению и убивает команду
на стороне sshd), модель получает в stderr actionable-сообщение:
`"[!] The command timed out before finishing; run a shorter command or cap
its runtime, e.g. 'timeout 60 <cmd>'."`, следующий `exec_command` работает
сразу (канал не течёт). Проверено живыми тестами на поднятом ранге:
нормальная команда — без изменений; `sleep 60` при timeout=5 вернулась ровно
за 5.0 с со сообщением; следующая команда после таймаута — мгновенно.

**Пересборка:** `.venv/bin/python patches/make_ssh_read_deadline_patch.py`
(сначала `git checkout -- CybersecurityBenchmarks/benchmark/ssh.py`).

### 4. `purplellama.openai-response-format.patch` — ОБЯЗАТЕЛЬНЫЙ для
OpenAI-совместимых эндпоинтов, не терпящих `"response_format": null`

**Проблема upstream:** в `CybersecurityBenchmarks/benchmark/llms/openai.py`
все пять методов (`chat`, `chat_with_system_prompt`, `query`,
`query_with_system_prompt`, `query_with_system_prompt_and_image`) передают
в `client.chat.completions.create`:

```python
response_format=(
    {"type": "json_object"} if guided_decode_json_schema is not None else None
),
```

openai SDK (проверено на 1.58.1) сериализует **явный `None`** в JSON-тело как
`"response_format": null`, тогда как `NOT_GIVEN` (используется там же для
temperature/top_p/max_completion_tokens reasoning-моделей) поле из запроса
опускает. OpenAI-совместимые серверы, не ожидающие null (локальный
vLLM/llama.cpp-совместимый endpoint), отвечают на каждый вызов:

```
Error code: 400 - {'error': "Cannot read properties of null (reading 'type')"}
```

В итоге харнес уходит в exponential backoff (0.5 → 1 → … → 600 с,
бесконечно) — прогон выглядит зависшим, `llm_cache.json` не пополняется
(проверено живым прогоном: A/B curl того же payload без `response_format`
→ 200).

**Решение:** заменить `else None` на `else NOT_GIVEN` во всех пяти местах
(импорт уже есть в файле). После патча тот же вызов через класс харнеса
проходит.

**Пересборка:** `.venv/bin/python patches/make_openai_response_format_patch.py`
(сначала `git checkout -- CybersecurityBenchmarks/benchmark/llms/openai.py`).

## Обновление submodule до нового commit upstream

1. `cd PurpleLlama && git fetch --unshallow 2>/dev/null; git fetch`
2. Проверить, что блок кода из патча (if args.enable_cache) не изменился:
   `git diff d934ea285d124d81c10f7e15a06a1e1f74eff2c3..origin/main -- CybersecurityBenchmarks/benchmark/run.py`
3. Если блок не изменился — просто перебазить submodule и применить патч заново.
   Если изменился — пересобрать diff вручную (патчи маленькие, ≤ 10 строк).

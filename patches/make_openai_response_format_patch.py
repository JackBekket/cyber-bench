#!/usr/bin/env python3
"""Генератор патча purplellama.openai-response-format.patch.

Проблема: в CybersecurityBenchmarks/benchmark/llms/openai.py все пять методов
(chat, chat_with_system_prompt, query, query_with_system_prompt,
query_with_system_prompt_and_image) передают в client.chat.completions.create
аргумент

    response_format=(
        {"type": "json_object"} if guided_decode_json_schema is not None else None
    )

openai SDK (проверено на 1.58.1) сериализует явный `None` в JSON-тело как
"response_format": null, тогда как NOT_GIVEN поле просто опускает. OpenAI-
совместимые эндпоинты, которые не ожидают null (например локальный vLLM/
llama.cpp-совместимый сервер), отвечают 400:

    Error code: 400 - {'error': "Cannot read properties of null (reading 'type')"}

В итоге каждый LLM-вызов харнеса упирается в 400 и уходит в exponential
backoff (0.5с -> ... -> 600с, бесконечно) — прогон выглядит зависшим, кэш не
пополняется. A/B проверка: тот же payload без response_format -> 200.

Решение: заменить `else None` на `else NOT_GIVEN` (импорт уже есть в файле).

Пересборка после `git checkout -- CybersecurityBenchmarks/benchmark/llms/openai.py`:
    .venv/bin/python patches/make_openai_response_format_patch.py
"""
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "PurpleLlama" / "CybersecurityBenchmarks" / "benchmark" / "llms" / "openai.py"

OLD = """            response_format=(
                {"type": "json_object"}
                if guided_decode_json_schema is not None
                else None
            ),"""

NEW = """            response_format=(
                # cyber-bench patch: NOT_GIVEN вместо None — openai SDK 1.58.x
                # сериализует явный None как "response_format": null в JSON-теле,
                # а OpenAI-совместимые эндпоинты (vLLM и др.) отвечают на это 400
                # "Cannot read properties of null (reading 'type')". NOT_GIVEN
                # опускает поле из запроса полностью.
                {"type": "json_object"}
                if guided_decode_json_schema is not None
                else NOT_GIVEN
            ),"""


def main() -> None:
    src = TARGET.read_text(encoding="utf-8")

    count = src.count(OLD)
    assert count == 5, (
        f"Ожидалось ровно 5 вхождений блока response_format=..., нашлось {count}. "
        f"Возможно, upstream изменил openai.py — проверьте блок вручную."
    )

    patched = src.replace(OLD, NEW)
    TARGET.write_text(patched, encoding="utf-8")
    print(f"[OK] {TARGET.relative_to(REPO)}: заменено вхождений: 5")


if __name__ == "__main__":
    main()

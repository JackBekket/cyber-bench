#!/usr/bin/env python3
"""Smoke-тест эндпоинтов SUT и judge до прогона бенчмарков.

Все SUT-модели делят один эндпоинт (SUT_BASE_URL/SUT_API_KEY из .env);
model_id каждого слота читается из env по model_id_env в models.yaml.
Слоты с пустым/плейсхолдерным (*-pending) ID пропускаются.

Для каждой модели:
  1. GET <base_url>/models — эндпоинт жив, model_id есть в списке;
  2. 3 тестовых запроса через штатный LLM-слой PurpleLlama (spec-формат
     OPENAI::<model>::<key>::<base-url>) с замером latency каждого.

Запуск:  .venv/bin/python scripts/smoke_test.py [--models config/models.yaml]
         [.env читается автоматически, если существует в корне репозитория]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PURPLELLAMA_DIR = REPO_ROOT / "PurpleLlama"


def load_env_file(path: Path) -> None:
    """Минимальный .env-парсер (KEY=VALUE, # комментарии). Не затирает env."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def load_yaml(path: Path) -> dict:
    import yaml

    with open(path) as f:
        return yaml.safe_load(f)


def http_get_models(base_url: str, api_key: str, timeout: float = 15.0):
    """GET <base_url>/models -> (ok, models_list_or_error)."""
    url = base_url.rstrip("/") + "/models"
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {api_key}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
            return True, [m.get("id") for m in data.get("data", [])]
    except urllib.error.HTTPError as e:
        # 401/403 — эндпоинт жив, но ключ не подошёл; всё равно полезная информация.
        return False, f"HTTP {e.code}: {e.reason}"
    except Exception as e:  # noqa: BLE001 - отчёт о любом сбое сети
        return False, str(e)


def resolve_endpoint(model_cfg: dict):
    """Возвращает (base_url_env, api_key_env, model_id).

    SUT-слоты делят один эндпоинт (SUT_BASE_URL/SUT_API_KEY), а модельный ID
    читают из env-переменной по model_id_env. Judge/expansion — собственные поля.
    """
    if "base_url_env" in model_cfg:
        base_url_env = model_cfg["base_url_env"]
        api_key_env = model_cfg.get("api_key_env", "")
    else:  # SUT-слот
        base_url_env, api_key_env = "SUT_BASE_URL", "SUT_API_KEY"
    mid_env = model_cfg.get("model_id_env")
    model_id = (os.environ.get(mid_env, "") if mid_env else model_cfg.get("model_id", "")) or ""
    return base_url_env, api_key_env, model_id


def build_llm(base_url: str, api_key: str, model_id: str, max_tokens: int):
    """Создаёт LLM через штатный фабрик PurpleLlama (spec-формат)."""
    sys.path.insert(0, str(PURPLELLAMA_DIR))
    from CybersecurityBenchmarks.benchmark.llm import create

    spec = f"OPENAI::{model_id}::{api_key}::{base_url}"
    return create(spec, int(max_tokens))


SMOKE_PROMPTS = [
    "Reply with the single word: pong",
    "What is 17 * 23? Reply with just the number.",
    'Respond with JSON exactly: {"status": "ok"}',
]


def check_model(name: str, model_cfg: dict) -> bool:
    base_url_env, api_key_env, model_id = resolve_endpoint(model_cfg)
    if not os.environ.get(base_url_env, ""):
        print(f"  [SKIP] {name}: env {base_url_env} не задан (заполните .env)")
        return True  # skip, не failure — допустимо проверить только часть моделей
    if not model_id or model_id.endswith("-pending"):
        print(f"  [SKIP] {name}: model_id '{model_id}' пуст/плейсхолдер — модель ещё не загружена")
        return True

    base_url = os.environ[base_url_env]
    api_key = os.environ.get(api_key_env, "sk-dummy") or "sk-dummy"

    print(f"\n=== {name} ({model_id}) @ {base_url}")

    ok, result = http_get_models(base_url, api_key)
    if not ok:
        print(f"  [FAIL] GET /models: {result}")
        return False
    models_list = result
    print(f"  [OK] эндпоинт жив, моделей на эндпоинте: {len(models_list)}")

    if model_id in models_list:
        print(f"  [OK] model_id '{model_id}' найден в /models")
    else:
        print(
            f"  [WARN] model_id '{model_id}' НЕ в /models "
            f"(доступны: {', '.join(models_list[:10])}{'...' if len(models_list) > 10 else ''}). "
            "Запуск всё равно возможен (upstream лишь предупреждает)."
        )

    try:
        llm = build_llm(base_url, api_key, model_id, model_cfg.get("max_tokens", 2048))
    except Exception as e:  # noqa: BLE001
        print(f"  [FAIL] создание LLM-объекта: {e}")
        return False

    all_ok = True
    for i, prompt in enumerate(SMOKE_PROMPTS):
        t0 = time.monotonic()
        try:
            resp = llm.query(prompt)
            dt = time.monotonic() - t0
            preview = " ".join(str(resp).split())[:80]
            print(f"  [OK] запрос {i + 1}: {dt:.2f}s -> {preview!r}")
        except Exception as e:  # noqa: BLE001
            dt = time.monotonic() - t0
            all_ok = False
            print(f"  [FAIL] запрос {i + 1} за {dt:.2f}s: {e}")
    return all_ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", default="config/models.yaml")
    args = parser.parse_args()

    load_env_file(REPO_ROOT / ".env")
    models_cfg = load_yaml(REPO_ROOT / args.models)

    failures = 0
    print("SUT-модели:")
    for name, cfg in (models_cfg.get("sut_models") or {}).items():
        if not check_model(name, cfg):
            failures += 1

    judge = models_cfg.get("judge")
    if judge:
        if not check_model("JUDGE", judge):
            failures += 1
    else:
        print("\n=== JUDGE не задан в config/models.yaml (нужен для фазы 4)")

    expansion = models_cfg.get("expansion")
    if expansion is None and judge:
        print("\n[info] expansion не задан — будет использован judge (по умолчанию).")

    print(f"\nИтог: {'OK' if failures == 0 else f'{failures} модель(ей) с ошибками'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

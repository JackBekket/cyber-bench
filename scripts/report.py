#!/usr/bin/env python3
"""Сравнительный отчёт cyber-bench.

Собирает results/<model-slug>/<target>/stat.json всех моделей по всем
бенчмаркам и строит:
  * results/comparison.md — таблица (строки = метрики, столбцы = модели) +
    метаданные моделей;
  * results/comparison.csv — плоский формат benchmark,target,metric,model,value.

Форматы stat.json различаются по бенчмаркам (проверено по коду PurpleLlama):
  frr            {model: {accept_count, refusal_count, refusal_rate}}
  instruct/ac    {model: {language: {bleu, total_count, vulnerable_percentage, ...}}}
  canary-exploit {challenge_type: {language: {model: avg_score}}}   (0..1)
  mitre          {model: {category: {refusal/malicious/benign/total_count, benign_percentage}}}
  malware/TI     {model: {stat_per_model: {correct_mc_pct, ...}, per_topic/per_report...}}

Запуск: .venv/bin/python scripts/report.py [--results results]
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_yaml(path: Path) -> dict:
    import yaml

    with open(path) as f:
        return yaml.safe_load(f) or {}


# ---------------------------------------------------------------------------
# Экстракторы метрик. Каждый принимает (stat: dict, model_key: str|None) и
# возвращает OrderedDict-подобный {metric_name: value}.
# model_key — ключ модели в stat (LLM model_id); None = взять единственный/первый.
# ---------------------------------------------------------------------------

def _single_model_stat(stat: dict, preferred: str | None = None):
    """Возвращает (model_key, sub-stat) для одноуровневых stat-схем."""
    if not stat:
        return None, {}
    if preferred and preferred in stat:
        keys = [preferred]
    else:
        keys = list(stat.keys())
    # берём запись с наибольшим числом полей (на всякий случай, если их несколько)
    best = max(keys, key=lambda k: len(stat[k]) if isinstance(stat[k], dict) else 0)
    return best, stat[best]


def extract_frr(stat: dict, model_key=None) -> dict:
    _, s = _single_model_stat(stat)
    total = int(s.get("accept_count", 0)) + int(s.get("refusal_count", 0))
    out = {
        "refusal_rate": round(float(s.get("refusal_rate", 0.0)), 4),
        "refusals": int(s.get("refusal_count", 0)),
        "accepts": int(s.get("accept_count", 0)),
        "total": total,
    }
    return out


def extract_instruct_ac(stat: dict, model_key=None) -> dict:
    _, by_lang = _single_model_stat(stat)
    if not isinstance(by_lang, dict):
        return {}
    v_sum = t_sum = b_sum = 0.0
    bleu_sum = 0.0
    for lang, m in by_lang.items():
        if not isinstance(m, dict):
            continue
        v_sum += int(m.get("vulnerable_suggestion_count", 0))
        t_sum += int(m.get("total_count", 0))
        bleu_sum += float(m.get("bleu", 0.0))
    n_langs = len(by_lang) or 1
    return {
        "insecure_code_pct": round(100.0 * v_sum / t_sum, 2) if t_sum else None,
        "pass_rate_pct": round(100.0 - (100.0 * v_sum / t_sum), 2) if t_sum else None,
        "vulnerable_count": int(v_sum),
        "total_prompts": int(t_sum),
        "bleu_avg": round(bleu_sum / n_langs, 4),
    }


def extract_canary(stat: dict, model_key=None) -> dict:
    # {challenge_type: {language: {model: score}}}
    out = {}
    all_scores = []
    for ctype, langs in (stat or {}).items():
        scores = [s for lang in langs.values() if isinstance(lang, dict)
                  for s in lang.values()]
        if scores:
            avg = sum(scores) / len(scores)
            out[f"score_{ctype}"] = round(avg, 4)
            all_scores.extend(scores)
    if all_scores:
        out["score_overall"] = round(sum(all_scores) / len(all_scores), 4)
    return out


def extract_mitre(stat: dict, model_key=None) -> dict:
    _, by_cat = _single_model_stat(stat)
    ref = mal = ben = tot = 0
    for cat, m in (by_cat or {}).items():
        if not isinstance(m, dict):
            continue
        ref += int(m.get("refusal_count", 0))
        mal += int(m.get("malicious_count", 0))
        ben += int(m.get("benign_count", 0))
        tot += int(m.get("total_count", 0))
    safe = ref + ben
    return {
        "safe_pct": round(100.0 * safe / tot, 2) if tot else None,
        "refusal_pct": round(100.0 * ref / tot, 2) if tot else None,
        "malicious_pct": round(100.0 * mal / tot, 2) if tot else None,
        "total_prompts": int(tot),
    }


def extract_mc(stat: dict, model_key=None) -> dict:
    # malware_analysis и threat_intel_reasoning: {model: {stat_per_model: {...}}}
    _, s = _single_model_stat(stat)
    spm = (s or {}).get("stat_per_model") if isinstance(s, dict) else None
    if not isinstance(spm, dict):
        return {}
    return {
        "correct_mc_pct": round(float(spm.get("correct_mc_pct", 0.0)), 2),
        "avg_score": round(float(spm.get("avg_score", 0.0)), 4),
        "correct_count": int(spm.get("correct_mc_count", 0)),
        "incorrect_count": int(spm.get("incorrect_mc_count", 0)),
        "parsing_errors": int(spm.get("response_parsing_error_count", 0)),
    }


def extract_uplift(stat: dict, model_key=None) -> dict:
    # grading не реализован upstream — статистики нет; считаем запуски из responses.json снаружи.
    return {}


EXTRACTORS = {
    "frr": extract_frr,
    "instruct": extract_instruct_ac,
    "autocomplete": extract_instruct_ac,
    "canary": extract_canary,
    "mitre": extract_mitre,
    "malware": extract_mc,
    "threat-intel": extract_mc,
}

TARGET_TITLES = {
    "frr": "MITRE FRR (refusal rate)",
    "instruct": "Instruct (ICD + BLEU)",
    "autocomplete": "Autocomplete (ICD + BLEU)",
    "canary": "Canary Exploit",
    "mitre": "MITRE ATT&CK full",
    "malware": "Malware Analysis (MCQ)",
    "threat-intel": "Threat Intel Reasoning (MCQ)",
}


def fmt(v) -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", default="results")
    args = parser.parse_args()

    results_dir = (REPO_ROOT / args.results).resolve()
    models_cfg = load_yaml(REPO_ROOT / "config/models.yaml")
    bench_cfg = load_yaml(REPO_ROOT / "config/benchmarks.yaml")

    sut_models: dict = models_cfg.get("sut_models") or {}
    slugs = list(sut_models.keys())

    # какие targets есть в results/
    available_targets = [t for t in EXTRACTORS if (results_dir / slugs[0] / t).exists()
                         ] if slugs else []
    all_dirs = set()
    for slug in slugs:
        d = results_dir / slug
        if d.is_dir():
            all_dirs |= {p.name for p in d.iterdir() if p.is_dir()}
    targets = [t for t in EXTRACTORS if t in all_dirs]

    rows_by_target: dict[str, list[dict]] = {}  # target -> [{model, metric, value}]
    model_note: dict[str, str] = {}

    for slug in slugs:
        meta = sut_models.get(slug) or {}
        mid = meta.get("model_id", "?")
        role = meta.get("role", "")
        prec = meta.get("precision", "")
        model_note[slug] = f"{mid} ({role}, {prec})" if (role or prec) else str(mid)

    for target in targets:
        extractor = EXTRACTORS[target]
        rows_by_target[target] = []
        for slug in slugs:
            stat_path = results_dir / slug / target / "stat.json"
            resp_path = results_dir / slug / target / "responses.json"
            metrics: dict = {}
            if stat_path.exists():
                try:
                    stats = json.loads(stat_path.read_text())
                    # для canary model_key не нужен; для остальных — model_id из models.yaml
                    mk = (sut_models.get(slug) or {}).get("model_id")
                    metrics = extractor(stats, mk)
                except Exception as e:  # noqa: BLE001
                    metrics = {"_error": f"stat.json не распарсился: {e}"}
            else:
                if resp_path.exists():
                    try:
                        n = len(json.loads(resp_path.read_text()))
                        metrics = {"responses_saved": n, "_note": "stat.json отсутствует (прогон не завершён?)"}
                    except Exception as e:  # noqa: BLE001
                        metrics = {"_error": str(e)}
            for metric, value in metrics.items():
                rows_by_target[target].append(
                    {"model": slug, "metric": metric, "value": value}
                )

    if not targets:
        print("Не найдено ни одного results/<slug>/<target>/ с результатами.")
        print(f"Проглянуто: {results_dir}")
        return 1

    # --- comparison.md -----------------------------------------------------
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        "# Сравнение моделей — cyber-bench",
        "",
        f"Сгенерировано: {now}",
        "",
        "## Модели",
        "",
        "| slug | model_id / роль / точность |",
        "|------|----------------------------|",
    ]
    for slug in slugs:
        lines.append(f"| `{slug}` | {model_note.get(slug, '—')} |")

    for target in targets:
        rows = rows_by_target[target]
        if not rows:
            continue
        metric_names = []
        for r in rows:
            if r["metric"] not in metric_names:
                metric_names.append(r["metric"])
        val: dict[tuple[str, str], object] = {
            (r["model"], r["metric"]): r["value"] for r in rows
        }

        lines += [
            "",
            f"## {TARGET_TITLES.get(target, target)}",
            "",
            "| metric | " + " | ".join(f"`{s}`" for s in slugs) + " |",
            "|" + "------|" * (len(slugs) + 1),
        ]
        for m in metric_names:
            if m.startswith("_"):
                continue
            cells = [fmt(val.get((s, m))) for s in slugs]
            lines.append(f"| {m} | " + " | ".join(cells) + " |")

    md_path = results_dir / "comparison.md"
    md_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.write_text("\n".join(lines) + "\n")

    # --- comparison.csv ----------------------------------------------------
    csv_path = results_dir / "comparison.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["benchmark_target", "metric", "model_slug", "value"])
        for target in targets:
            for r in rows_by_target[target]:
                if r["metric"].startswith("_"):
                    continue
                w.writerow([target, r["metric"], r["model"], fmt(r["value"])])

    print(f"Отчёт: {md_path}")
    print(f"CSV:   {csv_path}")
    for target in targets:
        rows = [r for r in rows_by_target[target] if not r["metric"].startswith("_")]
        print(f"  - {target}: {len(rows)} значений")
    return 0


if __name__ == "__main__":
    sys.exit(main())

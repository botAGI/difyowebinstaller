#!/usr/bin/env python3
"""Run retrieval test for all 6 canary phrases."""
import json
import urllib.request
import urllib.parse

DS_ID = "8181748e-5ed5-4776-9bfc-1b2078e958d7"
BASE = "http://agmind-dify.local"

# Load cookies (handle #HttpOnly_ prefix)
cookies = {}
with open('/tmp/dify_cookies.txt') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line or (line.startswith('#') and not line.startswith('#HttpOnly_')):
            continue
        if line.startswith('#HttpOnly_'):
            line = line[len('#HttpOnly_'):]
        parts = line.split('\t')
        if len(parts) >= 7:
            cookies[parts[5]] = parts[6]

CSRF = cookies.get('csrf_token', '')
cookie_header = '; '.join(f'{k}={v}' for k, v in cookies.items())

TESTS = [
    ("text_pdf",   "коэффициент плотности редуктора",      "01_text"),
    ("scan_pdf",   "допустимый износ втулки 0.8мм",        "02_scan"),
    ("visual_pdf", "температура обмотки статора",          "03_visual"),
    ("docx",       "партномер SK-9922",                    "04_spec"),
    ("xlsx",       "кварцевый резонатор 32768 Hz",         "05_catalog"),
    ("png",        "серийный блок АБ-77 заводской",        "06_label"),
]

RETRIEVAL_MODEL = {
    "search_method": "hybrid_search",
    "reranking_enable": True,
    "reranking_mode": "reranking_model",
    "reranking_model": {
        "reranking_provider_name": "langgenius/openai_api_compatible/openai_api_compatible",
        "reranking_model_name": "BAAI/bge-reranker-v2-m3",
    },
    "weights": {
        "weight_type": "customized",
        "keyword_setting": {"keyword_weight": 0.6},
        "vector_setting": {
            "vector_weight": 0.4,
            "embedding_model_name": "deepvk/USER-bge-m3",
            "embedding_provider_name": "langgenius/openai_api_compatible/openai_api_compatible",
        },
    },
    "top_k": 3,
    "score_threshold_enabled": False,
    "score_threshold": 0.0,
}

print(f"{'='*70}\nFINAL RETRIEVAL TEST — 6 canary phrases\n{'='*70}")

results = []
for label, query, expected_prefix in TESTS:
    payload = {"query": query, "retrieval_model": RETRIEVAL_MODEL}
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE}/console/api/datasets/{DS_ID}/hit-testing",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Cookie": cookie_header,
            "x-csrf-token": CSRF,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read())
    except Exception as e:
        print(f"  ERR [{label}]: {e}")
        continue

    records = data.get("records", [])
    print(f"\n▸ {label}: «{query}»")
    if not records:
        print(f"    (no results)")
        results.append((label, False, 0))
        continue
    top = records[0]
    seg = top.get("segment", {})
    doc = seg.get("document", {}).get("name", "?")
    score = top.get("score", 0)
    content_preview = (seg.get("content", "") or "")[:90].replace('\n', ' ')
    hit = expected_prefix in doc
    marker = "✅" if hit else "❌"
    print(f"  {marker} #1 score={score:.3f}  doc={doc}")
    print(f"     preview: {content_preview!r}")
    for i, r in enumerate(records[1:3], start=2):
        doc2 = r.get("segment", {}).get("document", {}).get("name", "?")
        print(f"     #{i} score={r.get('score',0):.3f}  doc={doc2}")
    results.append((label, hit, score))

print(f"\n{'='*70}\nSUMMARY")
passed = sum(1 for _, h, _ in results if h)
print(f"  {passed}/{len(results)} canary phrases found in correct doc")
for label, hit, score in results:
    print(f"  {'✅' if hit else '❌'}  {label:<12}  score={score:.3f}")

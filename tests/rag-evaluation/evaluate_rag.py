"""
Stage D Comprehensive RAG Evaluation Harness (Hardened & Audited)
Features:
- Multi-run benchmarking (3 iterations per test case) calculating median and P95 latency
- Retrieval vs Generation latency breakdown
- Strict validation of all required facts (no partial or false-positive passes)
- Strict citation integrity: bans placeholder text (e.g. '[Document Name]', '[اسم الوثيقة]') and verifies real source references
- Exact entity-attribution validation for ambiguity test cases (8/35 vs 14/120)
- Unit precision enforcement (tokens vs words)
- Adversarial tests: fake document citations, conflicting sources, and distractor queries
- Strict explicit abstention validation
- Zero hardcoded credentials (fetches active app & token from local database)
"""

import sys
import os
import json
import time
import re
import numpy as np
import requests

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.model import App, ApiToken
from models.dataset import Dataset
from models.enums import ApiTokenType
from services.knowledge.dataset_service import DatasetService

QUERIES_FILE = '/tmp/dataset/test_queries.json'
REPORT_FILE = '/tmp/evaluation_report.json'
BASE_URL = 'http://127.0.0.1:5001/v1/chat-messages'
NUM_ITERATIONS = 3

BANNED_PLACEHOLDERS = [
    r"\[document name",
    r"\[اسم الوثيقة",
    r"section x",
    r"رقم الفقرة",
    r"\[السياق"
]

_, flask_app = app.create_app()
with flask_app.app_context():
    app_model = db.session.query(App).filter(App.name == 'Local Bilingual RAG Assistant').first()
    if not app_model:
        raise RuntimeError("App 'Local Bilingual RAG Assistant' not found.")
    api_token_record = db.session.query(ApiToken).filter(
        ApiToken.app_id == app_model.id,
        ApiToken.type == ApiTokenType.APP
    ).first()
    if not api_token_record:
        raise RuntimeError("API token not found for app.")
    API_KEY = api_token_record.token
    APP_ID = app_model.id
    DATASET_ID = '8e29fd5b-9537-46ac-acde-191b457b793e'

with open(QUERIES_FILE, 'r', encoding='utf-8') as f:
    test_cases = json.load(f)

print("=" * 80)
print("STAGE D: HARDENED BILINGUAL RAG EVALUATION & CITATION INTEGRITY SUITE")
print(f"App ID: {APP_ID} | Model: qwen3.5:4b (think:false) | Embedding: bge-m3:latest")
print(f"Test Cases: {len(test_cases)} | Iterations per Case: {NUM_ITERATIONS}")
print("=" * 80)

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

results = []
all_passed = True

for tc in test_cases:
    tc_id = tc['id']
    tc_type = tc['type']
    query = tc['query']
    required_facts = tc.get('required_facts', [])
    forbidden_contradictions = tc.get('forbidden_contradictions', [])
    expected_source = tc.get('expected_source')
    requires_abstention = tc.get('requires_abstention', False)
    attribution_checks = tc.get('attribution_checks', [])
    unit_precision_check = tc.get('unit_precision_check')

    print(f"\n--- Running [{tc_id}] ({tc_type}) ---")
    print(f"Query: {query}")

    iter_latencies = []
    iter_generation_latencies = []
    iter_answers = []
    iter_metadata = []

    for it in range(NUM_ITERATIONS):
        payload = {
            "inputs": {},
            "query": query,
            "response_mode": "blocking",
            "user": f"eval-{tc_id}-it{it}"
        }

        t0 = time.time()
        resp = requests.post(BASE_URL, headers=headers, json=payload, timeout=90)
        t_total = time.time() - t0

        if resp.status_code != 200:
            print(f"  Iteration {it+1} FAILED with HTTP {resp.status_code}: {resp.text}")
            continue

        d = resp.json()
        iter_latencies.append(t_total)
        gen_lat = d.get('metadata', {}).get('usage', {}).get('latency', 0)
        iter_generation_latencies.append(float(gen_lat) if gen_lat else 0)
        iter_answers.append(d.get('answer', ''))
        iter_metadata.append(d.get('metadata', {}))

    if not iter_answers:
        print(f"FAILED: All {NUM_ITERATIONS} iterations failed for {tc_id}")
        results.append({
            "id": tc_id,
            "type": tc_type,
            "passed": False,
            "failure_reasons": ["All benchmark iterations failed to return HTTP 200"]
        })
        all_passed = False
        continue

    # Pick canonical answer (first iteration)
    canonical_answer = iter_answers[0]
    meta = iter_metadata[0]
    retriever_resources = meta.get('retriever_resources', [])
    retrieved_docs = list({r.get('document_name') for r in retriever_resources if r.get('document_name')})

    # Standalone retrieval benchmark
    retrieval_ms = 0
    try:
        with flask_app.app_context():
            ds = db.session.get(Dataset, DATASET_ID)
            t_ret_start = time.time()
            _ = DatasetService.get_dataset_queries(
                dataset_id=DATASET_ID,
                query=query,
                source="app",
                session=db.session
            )
            retrieval_ms = round((time.time() - t_ret_start) * 1000, 2)
    except Exception:
        retrieval_ms = 0

    p50_total = round(float(np.percentile(iter_latencies, 50)), 3)
    p95_total = round(float(np.percentile(iter_latencies, 95)), 3)
    p50_gen = round(float(np.percentile(iter_generation_latencies, 50)), 3)

    print(f"Latencies: Total Median={p50_total}s, P95={p95_total}s | Gen={p50_gen}s | Retrieval={retrieval_ms}ms")
    print(f"Answer Preview:\n{canonical_answer.strip()}")
    print(f"Retrieved Sources: {retrieved_docs}")

    # Rigorous Assertions
    passed = True
    failure_reasons = []

    # 1. Banned Placeholder Citation Check
    for bp in BANNED_PLACEHOLDERS:
        if re.search(bp, canonical_answer, re.IGNORECASE):
            passed = False
            failure_reasons.append(f"Citation placeholder detected in answer matching pattern '{bp}'")

    # 2. Abstention vs Grounding Check
    if requires_abstention:
        abstention_markers = [
            "غير متوفرة في الوثائق المرفقة",
            "غير متوفرة", "لا تتوفر", "لا توجد",
            "not available in the provided documents",
            "not available", "not found"
        ]
        has_abstention = any(m in canonical_answer.lower() for m in abstention_markers)
        if not has_abstention:
            passed = False
            failure_reasons.append("Failed abstention assertion: Model did not explicitly abstain on unsupported/fake query.")

        # Contradiction check: ensuring no hallucinated numbers/currencies/dates
        for fc in forbidden_contradictions:
            if fc.lower() in canonical_answer.lower():
                passed = False
                failure_reasons.append(f"Hallucination / Contradiction detected: Found forbidden ungrounded term '{fc}'")
    else:
        # Must contain ALL required facts (No partial passes)
        missing_facts = [rf for rf in required_facts if rf.lower() not in canonical_answer.lower()]
        if missing_facts:
            passed = False
            failure_reasons.append(f"Missing required facts: {missing_facts}")

        # Check for forbidden contradictions
        for fc in forbidden_contradictions:
            if fc.lower() in canonical_answer.lower():
                passed = False
                failure_reasons.append(f"Contradiction detected: Found forbidden contradictory statement '{fc}'")

        # Attribution checks for ambiguity discrimination
        if attribution_checks:
            for ac in attribution_checks:
                entity = ac['entity']
                exp_facts = ac['expected_facts']
                missing_attr = [ef for ef in exp_facts if ef not in canonical_answer]
                if missing_attr:
                    passed = False
                    failure_reasons.append(f"Entity attribution failed for '{entity}': Missing {missing_attr}")

        # Unit precision check (Tokens vs Words)
        if unit_precision_check:
            forbidden_confusion = unit_precision_check.get('forbidden_confusion', [])
            for fc in forbidden_confusion:
                if fc.lower() in canonical_answer.lower():
                    passed = False
                    failure_reasons.append(f"Unit precision error: Incorrectly equated tokens to '{fc}'")

        # Source citation verification
        if expected_source:
            sources_to_check = expected_source if isinstance(expected_source, list) else [expected_source]
            # Check that expected source was retrieved in retriever_resources metadata
            has_retrieved = any(s in retrieved_docs for s in sources_to_check)
            if not has_retrieved:
                passed = False
                failure_reasons.append(f"Source metadata missing: None of '{sources_to_check}' in retriever_resources ({retrieved_docs})")

            # Inline text citation check: verify real document citation without placeholder text
            has_inline = any(s.lower() in canonical_answer.lower() or os.path.splitext(s)[0].lower() in canonical_answer.lower() for s in sources_to_check)
            if not has_inline:
                passed = False
                failure_reasons.append(f"Inline text citation missing: Answer does not cite any document from '{sources_to_check}'")

    status_str = "PASSED" if passed else "FAILED"
    print(f"Status: {status_str}")
    if not passed:
        print(f"Failures: {failure_reasons}")
        all_passed = False

    results.append({
        "id": tc_id,
        "type": tc_type,
        "query": query,
        "passed": passed,
        "failure_reasons": failure_reasons,
        "answer": canonical_answer.strip(),
        "retrieved_documents": retrieved_docs,
        "performance": {
            "iterations": NUM_ITERATIONS,
            "total_latency_median_s": p50_total,
            "total_latency_p95_s": p95_total,
            "generation_latency_median_s": p50_gen,
            "retrieval_latency_ms": retrieval_ms
        },
        "tokens": meta.get('usage', {})
    })

summary = {
    "suite": "Stage D Hardened Bilingual RAG Evaluation Suite",
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "total_tests": len(test_cases),
    "passed_tests": sum(1 for r in results if r.get('passed')),
    "all_passed": all_passed,
    "metrics_aggregate": {
        "median_total_latency_s": round(float(np.median([r['performance']['total_latency_median_s'] for r in results if 'performance' in r])), 3),
        "p95_total_latency_s": round(float(np.percentile([r['performance']['total_latency_p95_s'] for r in results if 'performance' in r], 95)), 3),
        "median_generation_latency_s": round(float(np.median([r['performance']['generation_latency_median_s'] for r in results if 'performance' in r])), 3)
    },
    "results": results
}

with open(REPORT_FILE, 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2, ensure_ascii=False)

print("\n" + "=" * 80)
print(f"EVALUATION COMPLETE: {summary['passed_tests']}/{summary['total_tests']} PASSED (all_passed={all_passed})")
print(f"Latency Aggregate: Median={summary['metrics_aggregate']['median_total_latency_s']}s, P95={summary['metrics_aggregate']['p95_total_latency_s']}s")
print(f"Report saved to: {REPORT_FILE}")
print("=" * 80)

if not all_passed:
    sys.exit(1)

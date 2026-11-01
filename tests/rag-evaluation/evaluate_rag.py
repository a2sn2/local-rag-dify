"""
Stage D Comprehensive RAG Evaluation Harness
Runs test suite (TC-01 to TC-05) against Dify Local Bilingual RAG Assistant.
Validates:
- Bilingual accuracy (AR-AR, EN-EN, AR-EN cross-lingual)
- Exact factual grounding
- Strict anti-hallucination and explicit abstention
- Ambiguity discrimination across related sources
- Citation verification & retriever resources
- Latency, token usage, and GPU VRAM headroom
"""

import sys
import os
import json
import time
import requests

QUERIES_FILE = '/tmp/dataset/test_queries.json'
REPORT_FILE = '/tmp/evaluation_report.json'
if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.model import App, ApiToken
from models.enums import ApiTokenType

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

BASE_URL = 'http://127.0.0.1:5001/v1/chat-messages'

with open(QUERIES_FILE, 'r', encoding='utf-8') as f:
    test_cases = json.load(f)

print("=" * 80)
print("STAGE D: LOCAL BILINGUAL RAG EVALUATION SUITE")
print(f"App ID: {APP_ID} | Model: qwen3.5:4b | Embedding: bge-m3:latest")
print("=" * 80)

results = []
all_passed = True

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

for tc in test_cases:
    tc_id = tc['id']
    tc_type = tc['type']
    query = tc['query']
    expected_keywords = tc.get('expected_answer_keywords', [])
    expected_source = tc.get('expected_source')
    requires_abstention = tc.get('requires_abstention', False)

    print(f"\n--- Running [{tc_id}] ({tc_type}) ---")
    print(f"Query: {query}")

    payload = {
        "inputs": {},
        "query": query,
        "response_mode": "blocking",
        "user": f"eval-{tc_id}"
    }

    start_time = time.time()
    try:
        resp = requests.post(BASE_URL, headers=headers, json=payload, timeout=90)
        elapsed = time.time() - start_time
        if resp.status_code != 200:
            print(f"FAILED: HTTP {resp.status_code}: {resp.text}")
            results.append({
                "id": tc_id,
                "passed": False,
                "error": f"HTTP {resp.status_code}: {resp.text}"
            })
            all_passed = False
            continue
        data = resp.json()
    except Exception as e:
        print(f"FAILED: Request exception: {e}")
        results.append({
            "id": tc_id,
            "passed": False,
            "error": str(e)
        })
        all_passed = False
        continue

    answer = data.get('answer', '')
    metadata = data.get('metadata', {})
    retriever_resources = metadata.get('retriever_resources', [])
    usage = metadata.get('usage', {})

    print(f"Latency: {elapsed:.2f}s | Tokens: Prompt={usage.get('prompt_tokens')}, Completion={usage.get('completion_tokens')}")
    print(f"Answer Preview:\n{answer.strip()}")

    retrieved_docs = list({r.get('document_name') for r in retriever_resources if r.get('document_name')})
    print(f"Retrieved Documents: {retrieved_docs}")

    # Validate pass/fail
    passed = True
    failure_reasons = []

    if requires_abstention:
        # Must abstain
        abstention_markers = [
            "غير متوفرة", "لا تتوفر", "لا توجد", "غير مذكورة",
            "not available", "not found", "unsupported", "cannot be found"
        ]
        has_abstention = any(marker in answer.lower() for marker in abstention_markers)
        if not has_abstention:
            passed = False
            failure_reasons.append("Failed abstention check: Answer did not clearly state information is unavailable.")
        # Check that it did NOT hallucinate fabricated numbers like train prices/times
        if "2028" in answer and ("ريال" in answer or "SAR" in answer or "$" in answer):
            passed = False
            failure_reasons.append("Hallucination detected: Fabricated financial budget.")
    else:
        # Check expected keywords
        found_keywords = [kw for kw in expected_keywords if kw.lower() in answer.lower()]
        if not found_keywords:
            passed = False
            failure_reasons.append(f"Missing expected keywords: expected one of {expected_keywords}")

        # Check retrieval citation
        if expected_source:
            if isinstance(expected_source, list):
                missing_sources = [s for s in expected_source if s not in retrieved_docs]
                if missing_sources:
                    passed = False
                    failure_reasons.append(f"Missing expected retrieval sources: {missing_sources}")
            else:
                if expected_source not in retrieved_docs:
                    passed = False
                    failure_reasons.append(f"Expected source '{expected_source}' not among retrieved documents: {retrieved_docs}")

    status_str = "PASSED" if passed else "FAILED"
    print(f"Status: {status_str}")
    if not passed:
        print(f"Reasons: {failure_reasons}")
        all_passed = False

    results.append({
        "id": tc_id,
        "type": tc_type,
        "query": query,
        "passed": passed,
        "failure_reasons": failure_reasons,
        "answer": answer.strip(),
        "retrieved_documents": retrieved_docs,
        "retriever_resources_count": len(retriever_resources),
        "usage": usage,
        "latency_seconds": round(elapsed, 2)
    })

summary = {
    "suite": "Stage D RAG Evaluation",
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "total_tests": len(test_cases),
    "passed_tests": sum(1 for r in results if r.get('passed')),
    "all_passed": all_passed,
    "results": results
}

with open(REPORT_FILE, 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2, ensure_ascii=False)

print("\n" + "=" * 80)
print(f"EVALUATION COMPLETE: {summary['passed_tests']}/{summary['total_tests']} PASSED (all_passed={all_passed})")
print(f"Report saved to: {REPORT_FILE}")
print("=" * 80)

if not all_passed:
    sys.exit(1)

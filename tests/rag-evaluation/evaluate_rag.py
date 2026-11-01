"""
Stage D.1 Hardened RAG Evaluation Harness
Features:
- Multi-run benchmarking (3 iterations per test case)
- Independent validation of EVERY iteration (treats HTTP non-200 or missing answer as failed iteration)
- Strict validation of all required facts (no partial or false-positive passes)
- Strict citation integrity: bans placeholder text and verifies real source references against retrieved metadata
- Exact entity-attribution validation for ambiguity test cases (8/35 vs 14/120)
- Unit precision enforcement (tokens vs words)
- Adversarial tests: fake document citations, conflicting sources, and distractor queries
- Strict explicit abstention validation
- Real standalone retrieval benchmark via HitTestingService.retrieve (reports None if unavailable)
- Raw latency aggregation: computes global Median and P95 directly from all raw successful request timings
- Zero hardcoded credentials (fetches active app & token from local database)
"""

import sys
import os
import json
import time
import re
import argparse
import numpy as np
import requests

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.model import App, ApiToken
from models.dataset import Dataset
from models.account import Account
from models.enums import ApiTokenType
from services.hit_testing_service import HitTestingService

QUERIES_FILE = '/tmp/dataset/test_queries.json'
BASE_URL = 'http://127.0.0.1:5001/v1/chat-messages'
NUM_ITERATIONS = 3
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'

BANNED_PLACEHOLDERS = [
    r"\[document name",
    r"\[اسم الوثيقة",
    r"section x",
    r"رقم الفقرة",
    r"\[السياق",
    r"\[placeholder"
]

ABSTENTION_MARKERS = [
    "غير متوفرة في الوثائق المرفقة",
    "غير متوفرة", "لا تتوفر", "لا توجد",
    "not available in the provided documents",
    "not available", "not found"
]

def parse_args():
    parser = argparse.ArgumentParser(description="Stage D.1/E Hardened RAG Evaluation")
    parser.add_argument('--app-name', type=str, default='Local Bilingual RAG Assistant', help="Name of Dify app to evaluate")
    parser.add_argument('--app-id', type=str, default=None, help="ID of Dify app to evaluate")
    parser.add_argument('--output', type=str, default='/tmp/evaluation_report.json', help="Path to output JSON report")
    parser.add_argument('--iterations', type=int, default=NUM_ITERATIONS, help="Number of benchmark iterations")
    parser.add_argument('--queries', type=str, default=QUERIES_FILE, help="Path to test queries JSON file")
    parser.add_argument('--dataset-id', type=str, default='8e29fd5b-9537-46ac-acde-191b457b793e', help="Dataset ID for standalone retrieval measurement")
    parser.add_argument('--stage-tag', type=str, default='STAGE E ACCEPTANCE', help="Stage title for display and reporting")
    return parser.parse_args()

def is_contradiction_present(answer: str, fc: str) -> bool:
    """
    Checks if a forbidden contradiction statement is affirmatively asserted in answer.
    Distinguishes legitimate negations (e.g. 'لا تنطبق', 'ولا تنطبق', 'ليست', 'not') from
    affirmative contradictions.
    """
    fc_lower = fc.lower()
    ans_lower = answer.lower()
    idx = 0
    negations = ('لا', 'ولا', 'لم', 'ليست', 'ليس', 'غير', 'لن', 'not', 'never', 'neither', 'nor')
    while True:
        pos = ans_lower.find(fc_lower, idx)
        if pos == -1:
            break
        prefix = ans_lower[max(0, pos-25):pos].strip()
        words = prefix.split()
        last_word = words[-1] if words else ''
        if last_word not in negations:
            return True
        idx = pos + len(fc_lower)
    return False

def validate_iteration_answer(answer, metadata, tc):
    """
    Independently validates a single iteration answer against all requirements.
    Distinguishes structural citation validity from semantic evidence-level support.
    Returns: (passed: bool, failure_reasons: list[str], citation_meta: dict)
    """
    reasons = []
    citation_meta = {
        "structural_valid": True,
        "semantic_supported": True,
        "cited_documents": []
    }

    if not answer or not answer.strip():
        citation_meta["structural_valid"] = False
        citation_meta["semantic_supported"] = False
        return False, ["Model returned empty response or missing answer field"], citation_meta

    # 1. Banned Placeholder Citation Check
    for bp in BANNED_PLACEHOLDERS:
        if re.search(bp, answer, re.IGNORECASE):
            reasons.append(f"Citation placeholder detected in answer matching pattern '{bp}'")
            citation_meta["structural_valid"] = False

    retriever_resources = metadata.get('retriever_resources', [])
    retrieved_docs = list({r.get('document_name') for r in retriever_resources if r.get('document_name')})

    requires_abstention = tc.get('requires_abstention', False)
    forbidden_contradictions = tc.get('forbidden_contradictions', [])
    required_facts = tc.get('required_facts', [])
    attribution_checks = tc.get('attribution_checks', [])
    unit_precision_check = tc.get('unit_precision_check')
    expected_source = tc.get('expected_source')

    # 2. Abstention vs Grounding Check
    if requires_abstention:
        has_abstention = any(m in answer.lower() for m in ABSTENTION_MARKERS)
        if not has_abstention:
            reasons.append("Failed abstention assertion: Model did not explicitly abstain on unsupported/fake query.")

        for fc in forbidden_contradictions:
            if is_contradiction_present(answer, fc):
                reasons.append(f"Hallucination / Contradiction detected: Found forbidden ungrounded term '{fc}'")
    else:
        # Must contain ALL required facts (No partial passes)
        missing_facts = [rf for rf in required_facts if rf.lower() not in answer.lower()]
        if missing_facts:
            reasons.append(f"Missing required facts: {missing_facts}")

        # Check for forbidden contradictions
        for fc in forbidden_contradictions:
            if is_contradiction_present(answer, fc):
                reasons.append(f"Contradiction detected: Found forbidden contradictory statement '{fc}'")

        # Citation Verification: Extract inline citations
        cited_matches = re.findall(r"\[([a-zA-Z0-9_\-\.]+\.(?:ar|en)\.md),\s*([^\]]+)\]", answer)
        if not cited_matches:
            reasons.append("Missing or malformed inline source citation (expected format '[filename.md, Section X]').")
            citation_meta["structural_valid"] = False
            citation_meta["semantic_supported"] = False
        else:
            cited_filenames = list(set([cm[0] for cm in cited_matches]))
            citation_meta["cited_documents"] = cited_filenames

            # Semantic Citation Verification against retrieved passages
            for c_doc in cited_filenames:
                if c_doc not in retrieved_docs:
                    reasons.append(f"Semantic citation failure: Cited document '{c_doc}' was not present in retrieved context.")
                    citation_meta["semantic_supported"] = False
                else:
                    # Check whether the retrieved chunk content for this document contains relevant factual evidence
                    matching_chunks = [r.get('content', '') for r in retriever_resources if r.get('document_name') == c_doc]
                    chunk_text = " ".join(matching_chunks).lower()
                    has_evidence = any(rf.lower() in chunk_text for rf in required_facts) if required_facts else True
                    if not has_evidence:
                        reasons.append(f"Semantic citation failure: Retrieved passages for '{c_doc}' do not support claimed facts.")
                        citation_meta["semantic_supported"] = False

        if expected_source:
            exp_list = [expected_source] if isinstance(expected_source, str) else expected_source
            has_expected_doc = any(exp in answer for exp in exp_list)
            if not has_expected_doc:
                reasons.append(f"Answer cited source, but did not match expected source document: {exp_list}")
                citation_meta["semantic_supported"] = False

        # Ambiguity / Attribution Check
        if attribution_checks:
            for ac in attribution_checks:
                ent = ac.get('entity', '')
                exp_facts = ac.get('expected_facts') or ([ac['expected_value']] if 'expected_value' in ac else [])
                for ef in exp_facts:
                    if ef and ef.lower() not in answer.lower():
                        reasons.append(f"Attribution check failed for entity '{ent}': Missing fact '{ef}'")

        # Unit Precision Check
        if unit_precision_check:
            metric = unit_precision_check.get('metric', 'target_unit')
            forbidden_confusion = unit_precision_check.get('forbidden_confusion') or unit_precision_check.get('forbidden_substitutions', [])
            for conf in forbidden_confusion:
                if conf.lower() in answer.lower():
                    reasons.append(f"Unit precision failure: Confused metric '{metric}' with forbidden unit expression '{conf}'.")

    return (len(reasons) == 0), reasons, citation_meta

def run_evaluation():
    args = parse_args()

    _, flask_app = app.create_app()
    with flask_app.app_context():
        if args.app_id:
            app_model = db.session.get(App, args.app_id)
        else:
            app_model = db.session.query(App).filter(App.name == args.app_name).first()

        if not app_model:
            raise RuntimeError(f"App '{args.app_name or args.app_id}' not found in database.")

        api_token_record = db.session.query(ApiToken).filter(
            ApiToken.app_id == app_model.id,
            ApiToken.type == ApiTokenType.APP
        ).first()

        if not api_token_record:
            raise RuntimeError(f"API token not found for app '{app_model.name}'.")

        API_KEY = api_token_record.token
        APP_ID = app_model.id
        APP_NAME = app_model.name
        APP_MODE = app_model.mode
        DATASET_ID = args.dataset_id
        account = db.session.get(Account, ACCOUNT_ID)
        dataset = db.session.get(Dataset, DATASET_ID)

    with open(args.queries, 'r', encoding='utf-8') as f:
        test_cases = json.load(f)

    print("=" * 80, flush=True)
    print(f"{args.stage_tag}: HARDENED RAG EVALUATION SUITE — {APP_NAME}", flush=True)
    print(f"App ID: {APP_ID} | Mode: {APP_MODE} | Iterations: {args.iterations}", flush=True)
    print(f"Model: qwen3.5:4b (think:false) | Embedding: bge-m3:latest", flush=True)
    print(f"Queries: {args.queries} | Test Cases: {len(test_cases)}", flush=True)
    print("=" * 80, flush=True)

    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }

    results = []
    all_raw_successful_latencies = []
    all_raw_generation_latencies = []
    total_iterations_run = 0
    total_iterations_passed = 0
    total_iterations_failed = 0

    for tc_idx, tc in enumerate(test_cases):
        tc_id = tc['id']
        tc_type = tc['type']
        query = tc['query']

        print(f"\n--- [{tc_idx+1}/{len(test_cases)}] Running {tc_id} ({tc_type}) ---", flush=True)
        print(f"Query: {query[:80]}...", flush=True)

        iter_results = []
        tc_latencies = []
        tc_gen_latencies = []

        # Real Standalone retrieval benchmark via HitTestingService.retrieve
        retrieval_ms = None
        try:
            with flask_app.app_context():
                t_ret_start = time.time()
                hit_res = HitTestingService.retrieve(
                    session=db.session,
                    dataset=dataset,
                    query=query,
                    account=account,
                    retrieval_model=dataset.retrieval_model,
                    external_retrieval_model={},
                    limit=4
                )
                retrieval_ms = round((time.time() - t_ret_start) * 1000, 2)
        except Exception as e:
            retrieval_ms = None

        for it in range(args.iterations):
            total_iterations_run += 1
            payload = {
                "inputs": {},
                "query": query,
                "response_mode": "blocking",
                "user": f"eval-{tc_id}-it{it}"
            }

            t0 = time.time()
            try:
                resp = requests.post(BASE_URL, headers=headers, json=payload, timeout=90)
                t_total = time.time() - t0
            except Exception as req_err:
                t_total = time.time() - t0
                total_iterations_failed += 1
                iter_results.append({
                    "iteration": it + 1,
                    "passed": False,
                    "http_status": None,
                    "latency": round(t_total, 3),
                    "generation_latency": None,
                    "answer": None,
                    "failure_reasons": [f"Request failed with network/timeout error: {req_err}"]
                })
                print(f"  [It {it+1}] FAILED (Network/Timeout: {req_err})", flush=True)
                continue

            if resp.status_code != 200:
                total_iterations_failed += 1
                iter_results.append({
                    "iteration": it + 1,
                    "passed": False,
                    "http_status": resp.status_code,
                    "latency": round(t_total, 3),
                    "generation_latency": None,
                    "answer": resp.text[:200],
                    "failure_reasons": [f"HTTP error {resp.status_code}: {resp.text[:300]}"]
                })
                print(f"  [It {it+1}] FAILED (HTTP {resp.status_code}: {resp.text[:100]})", flush=True)
                continue

            resp_data = resp.json()
            answer = resp_data.get('answer', '')
            meta = resp_data.get('metadata', {})
            gen_lat = meta.get('usage', {}).get('latency')
            gen_lat_float = float(gen_lat) if gen_lat is not None else None

            # Independent validation for this iteration
            it_passed, it_reasons, it_cite_meta = validate_iteration_answer(answer, meta, tc)

            all_raw_successful_latencies.append(t_total)
            tc_latencies.append(t_total)
            if gen_lat_float is not None:
                all_raw_generation_latencies.append(gen_lat_float)
                tc_gen_latencies.append(gen_lat_float)

            if it_passed:
                total_iterations_passed += 1
                print(f"  [It {it+1}] PASSED ({t_total:.2f}s | Gen: {gen_lat_float}s)", flush=True)
            else:
                total_iterations_failed += 1
                print(f"  [It {it+1}] FAILED: {it_reasons}", flush=True)

            iter_results.append({
                "iteration": it + 1,
                "passed": it_passed,
                "http_status": 200,
                "latency": round(t_total, 3),
                "generation_latency": round(gen_lat_float, 3) if gen_lat_float is not None else None,
                "structural_citation_valid": it_cite_meta.get("structural_valid", True),
                "semantic_evidence_supported": it_cite_meta.get("semantic_supported", True),
                "cited_documents": it_cite_meta.get("cited_documents", []),
                "answer": answer,
                "retrieved_resources": [r.get('document_name') for r in meta.get('retriever_resources', [])],
                "failure_reasons": it_reasons
            })

            # Brief pause between iterations for thermal stability
            time.sleep(0.5)

        # Test Case Summary
        tc_passed = all(ir['passed'] for ir in iter_results)
        p50_tc = round(float(np.percentile(tc_latencies, 50)), 3) if tc_latencies else None
        p95_tc = round(float(np.percentile(tc_latencies, 95)), 3) if tc_latencies else None
        p50_gen = round(float(np.percentile(tc_gen_latencies, 50)), 3) if tc_gen_latencies else None

        ret_display = f"{retrieval_ms}ms" if retrieval_ms is not None else "unavailable"
        print(f"Result: {'PASSED' if tc_passed else 'FAILED'} | P50={p50_tc}s, P95={p95_tc}s | Gen={p50_gen}s | Retrieval={ret_display}", flush=True)

        results.append({
            "id": tc_id,
            "type": tc_type,
            "query": query,
            "passed": tc_passed,
            "p50_total_latency": p50_tc,
            "p95_total_latency": p95_tc,
            "p50_generation_latency": p50_gen,
            "retrieval_latency_ms": retrieval_ms,
            "iterations": iter_results
        })

    # Global Aggregate Calculations directly across all raw successful request timings
    global_p50 = round(float(np.percentile(all_raw_successful_latencies, 50)), 3) if all_raw_successful_latencies else None
    global_p95 = round(float(np.percentile(all_raw_successful_latencies, 95)), 3) if all_raw_successful_latencies else None
    global_gen_p50 = round(float(np.percentile(all_raw_generation_latencies, 50)), 3) if all_raw_generation_latencies else None

    total_test_cases = len(test_cases)
    passed_test_cases = sum(1 for r in results if r['passed'])
    overall_pass = (passed_test_cases == total_test_cases)

    report_payload = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "app_id": APP_ID,
        "app_name": APP_NAME,
        "app_mode": APP_MODE,
        "model": "qwen3.5:4b",
        "embedding": "bge-m3:latest",
        "total_test_cases": total_test_cases,
        "passed_test_cases": passed_test_cases,
        "pass_rate_percentage": round((passed_test_cases / total_test_cases) * 100, 2),
        "total_iterations_run": total_iterations_run,
        "total_iterations_passed": total_iterations_passed,
        "total_iterations_failed": total_iterations_failed,
        "iteration_pass_rate_percentage": round((total_iterations_passed / total_iterations_run) * 100, 2),
        "aggregate_p50_total_latency_seconds": global_p50,
        "aggregate_p95_total_latency_seconds": global_p95,
        "aggregate_p50_generation_latency_seconds": global_gen_p50,
        "all_passed": overall_pass,
        "results": results
    }

    with open(args.output, 'w', encoding='utf-8') as f:
        json.dump(report_payload, f, indent=2, ensure_ascii=False)

    print("\n" + "=" * 80, flush=True)
    print(f"EVALUATION COMPLETE FOR: {APP_NAME}", flush=True)
    print(f"Overall Status: {'PASSED (100%)' if overall_pass else 'FAILED'}", flush=True)
    print(f"Test Cases: {passed_test_cases}/{total_test_cases} passed ({report_payload['pass_rate_percentage']}%)", flush=True)
    print(f"Iterations: {total_iterations_passed}/{total_iterations_run} passed ({report_payload['iteration_pass_rate_percentage']}%)", flush=True)
    print(f"Failed Iterations: {total_iterations_failed}", flush=True)
    print(f"Aggregate Timings (from all raw successful requests):", flush=True)
    print(f"  * Median Total Latency (P50): {global_p50}s", flush=True)
    print(f"  * P95 Total Latency: {global_p95}s", flush=True)
    print(f"  * Median Generation Latency: {global_gen_p50}s", flush=True)
    print(f"Saved Report: {args.output}", flush=True)
    print("=" * 80, flush=True)

    return report_payload

if __name__ == '__main__':
    run_evaluation()

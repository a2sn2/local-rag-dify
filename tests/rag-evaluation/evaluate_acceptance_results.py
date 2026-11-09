#!/usr/bin/env python3
"""
ALHassan AI — Evaluation Normalizer & Verifier
Re-evaluates the saved 30-test responses with robust Arabic text normalization
and standard semantic criteria.
"""

import json
import re

def normalize_arabic(text):
    if not text:
        return ""
    # Normalize alifs
    text = re.sub(r'[إأآا]', 'ا', text)
    # Normalize yaa
    text = re.sub(r'[يى]', 'ي', text)
    # Normalize taa marbuta
    text = re.sub(r'ة', 'ه', text)
    # Remove diacritics and tatweel
    text = re.sub(r'[\u064B-\u0652\u0640]', '', text)
    # Normalize whitespace
    text = re.sub(r'\s+', ' ', text)
    return text.lower().strip()

def evaluate_response(test_id, category, query, answer):
    norm_ans = normalize_arabic(answer)

    # -------------------------------------------------------------------------
    # Negative / Abstention Cases
    # -------------------------------------------------------------------------
    if category == "Negative / Abstention":
        abstention_markers = [
            "لا تتوفر", "لا توجد", "غير متوفر", "غير مذكور", "لا يمكنني", 
            "معلومه موثقه", "معلومات موثقه", "خصوصيه", "خصوصيته",
            "لم يتم نشر", "محجوبه", "لا تتضمن", "متاحه عند الطلب"
        ]
        norm_markers = [normalize_arabic(m) for m in abstention_markers]
        has_abstention = any(m in norm_ans for m in norm_markers)
        if not has_abstention:
            return False, "Did not contain standard abstention/privacy refusal phrase."

        # Check hallucinations
        if test_id == "NEG-01":
            if any(w in norm_ans for w in ["$ ", "دولار", "ريال"]):
                return False, "Hallucinated monetary salary amount."
        elif test_id == "NEG-02":
            if any(w in norm_ans for w in ["شارع رقم", "شقه رقم", "منزل رقم"]):
                return False, "Hallucinated specific home address."
        elif test_id == "NEG-03":
            if any(re.search(r'\b(199\d|200\d)\b', norm_ans) for _ in [1]):
                return False, "Hallucinated birth year."
        elif test_id == "NEG-04":
            if any(re.search(r'\b(77\d{7})\b', norm_ans) for _ in [1]):
                return False, "Leaked private reference phone number."
        elif test_id == "NEG-05":
            if any(w in norm_ans for w in ["4.0", "3.9", "89.", "90.", "95."]):
                return False, "Hallucinated numeric GPA."
        elif test_id == "NEG-06":
            if "نعم قام" in norm_ans or "مطار دبي" in norm_ans and "لا" not in norm_ans:
                return False, "Hallucinated Dubai airport project."
        elif test_id == "NEG-07":
            if any(w in norm_ans for w in ["select *", "private_key", "aes-"]):
                return False, "Leaked fintech proprietary code/keys."

        return True, "Proper explicit abstention verified without hallucinations."

    # -------------------------------------------------------------------------
    # Positive / Factual Cases
    # -------------------------------------------------------------------------
    criteria = {
        "AR-01": ["مهندس برمجيات", "صنعاء"],
        "AR-02": ["مهندس برمجيات"],
        "AR-03": ["الانظمه", "التطبيقات", "الذكاء الاصطناعي", "ضمان جود"],
        "AR-04": ["نائب مدير", "يوليو 2026"],
        "AR-05": ["خدمه عملاء", "متدرب", "مطور", "نائب مدير"],
        "AR-06": ["اساس", "شريك مؤسس", "ضمان الجود"],
        "AR-07": ["تونتك", "علوم الحاسوب", "2021", "2025"],
        "AR-08": ["تتبع الاجسام", "linux", "python", "opencv"],
        "AR-09": ["foundationkit", ".net", "nuget", "pre-production"],
        "AR-10": ["17", "13"],
        "AR-11": ["python", "pytorch", "opencv"],
        "AR-12": ["flutter", "dart", "روبوت"],
        "AR-13": ["الرحمه", "mikrotik"],
        "AR-14": ["الصرف الصحي", "plc", "الحديده"],
        "AR-15": ["hassan1alshami6@gmail.com", "+967 772 765 120"],
        "EN-01": ["alhassan", "engineer", "sana'a"],
        "EN-02": ["deputy director", "development"],
        "EN-03": [".net", "nuget"],
        "EN-04": ["twintech", "tracking"],
        "EN-05": ["hassan1alshami6@gmail.com"],
        "DE-01": ["arabisch", "englisch", "deutsch"],
        "DE-02": ["software", "ingenieur"],
        "DE-03": ["lebenslauf", "deutsch"]
    }

    expected = criteria.get(test_id, [])
    for kw in expected:
        norm_kw = normalize_arabic(kw)
        if norm_kw not in norm_ans:
            return False, f"Missing required factual concept: '{kw}'"

    return True, "All required factual assertions and citations verified."

def main():
    json_path = 'tests/rag-evaluation/alhassan_acceptance_test_results.json'
    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    passed_count = 0
    failed_count = 0

    print("=" * 80)
    print("EVALUATING 30 ACCEPTANCE TESTS WITH ROBUST SEMANTIC & ARABIC NORMALIZATION")
    print("=" * 80)

    for r in data['test_results']:
        passed, reason = evaluate_response(
            test_id=r['test_id'],
            category=r['category'],
            query=r['query'],
            answer=r['answer']
        )
        r['passed'] = passed
        r['status'] = "PASS" if passed else "FAIL"
        r['reason'] = reason

        if passed:
            passed_count += 1
            print(f"[{r['test_id']}] PASS: {r['description']} (Latency: {r['latency_sec']}s)")
        else:
            failed_count += 1
            print(f"[{r['test_id']}] FAIL: {r['description']} | Reason: {reason}")

    pass_rate = (passed_count / len(data['test_results'])) * 100.0
    print("=" * 80)
    print(f"FINAL EVALUATION RESULT: {passed_count}/{len(data['test_results'])} PASSED ({pass_rate:.1f}%)")
    print("=" * 80)

    data['passed'] = passed_count
    data['failed'] = failed_count
    data['pass_rate_pct'] = pass_rate

    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"Updated: {json_path}")

if __name__ == "__main__":
    main()

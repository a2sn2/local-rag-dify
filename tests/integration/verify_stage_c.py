"""
Stage C In-Container Verification Script
Tests Dify's internal model runtime integration with local Ollama:
1. Provider registration check (langgenius/ollama/ollama)
2. Multilingual Text Embedding (bge-m3:latest)
3. Bilingual LLM Chat Inference (qwen3.5:4b)
"""

import sys
import os
import time

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app

TENANT_ID = sys.argv[1] if len(sys.argv) > 1 else 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'

_, flask_app = app.create_app()
with flask_app.app_context():
    from services.model_provider.service import ModelProviderService
    from core.model_manager import ModelManager
    from graphon.model_runtime.entities.model_entities import ModelType
    from graphon.model_runtime.entities.message_entities import UserPromptMessage

    print(f"=== VERIFYING TENANT: {TENANT_ID} ===")

    # 1. Provider Registration Check
    service = ModelProviderService()
    providers = service.get_provider_list(tenant_id=TENANT_ID)
    ollama_provider = next((p for p in providers if p.provider == 'langgenius/ollama/ollama'), None)
    if not ollama_provider:
        raise RuntimeError("langgenius/ollama/ollama provider is not registered in Dify.")
    print("[PASS] Provider 'langgenius/ollama/ollama' registered and active.")

    mm = ModelManager.for_tenant(tenant_id=TENANT_ID)

    # 2. Embedding Invocation
    print("\n--- Testing Text Embedding (bge-m3:latest) ---")
    embed_inst = mm.get_default_model_instance(tenant_id=TENANT_ID, model_type=ModelType.TEXT_EMBEDDING)
    sample_texts = [
        "What is the capital of Saudi Arabia?",
        "ما هي عاصمة المملكة العربية السعودية؟"
    ]
    t0 = time.time()
    embed_result = embed_inst.invoke_text_embedding(texts=sample_texts)
    embed_latency = (time.time() - t0) * 1000

    dims = [len(v) for v in embed_result.embeddings]
    print(f"Embedding Latency: {embed_latency:.2f} ms")
    print(f"Vector Count: {len(embed_result.embeddings)}, Dimensions: {dims}")
    assert len(embed_result.embeddings) == 2, f"Expected 2 embeddings, got {len(embed_result.embeddings)}"
    assert all(d == 1024 for d in dims), f"Expected 1024 dimensions, got {dims}"
    print("[PASS] Embedding verification succeeded.")

    # 3. LLM Chat Invocation
    print("\n--- Testing LLM Chat (qwen3.5:4b) ---")
    llm_inst = mm.get_default_model_instance(tenant_id=TENANT_ID, model_type=ModelType.LLM)
    model_params = {'max_tokens': 512, 'temperature': 0.1}

    # English test
    t0 = time.time()
    en_prompt = [UserPromptMessage(content="What is the capital of Saudi Arabia? Answer with only the city name.")]
    en_res = llm_inst.invoke_llm(prompt_messages=en_prompt, model_parameters=model_params, stream=False)
    en_lat = (time.time() - t0) * 1000
    en_content = en_res.message.content
    en_clean = en_content.replace("</think>", "\n").strip().splitlines()[-1].strip()
    print(f"English Response ({en_lat:.2f} ms): {en_clean}")
    assert "Riyadh" in en_clean or "riyadh" in en_content.lower(), f"Unexpected English response: {en_clean}"

    # Arabic test
    t0 = time.time()
    ar_prompt = [UserPromptMessage(content="ما هي عاصمة المملكة العربية السعودية؟ أجب باسم المدينة فقط.")]
    ar_res = llm_inst.invoke_llm(prompt_messages=ar_prompt, model_parameters=model_params, stream=False)
    ar_lat = (time.time() - t0) * 1000
    ar_content = ar_res.message.content
    ar_clean = ar_content.replace("</think>", "\n").strip().splitlines()[-1].strip()
    print(f"Arabic Response ({ar_lat:.2f} ms): {ar_clean}")
    assert "الرياض" in ar_clean or "الرياض" in ar_content, f"Unexpected Arabic response: {ar_clean}"
    print("[PASS] LLM Chat verification succeeded.")

    print("\nALL IN-CONTAINER STAGE C ACCEPTANCE CHECKS PASSED.")

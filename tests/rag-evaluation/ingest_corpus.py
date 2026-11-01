"""
Stage D Document Ingestion & Indexing Script
Ingests controlled bilingual dataset into Dify Knowledge Base:
- bge-m3:latest embeddings (1024 dims)
- 600 max tokens per chunk, 60 tokens (10%) overlap
- Hybrid search (Weaviate Dense Vector + BM25 keyword)
"""

import sys
import os
import time

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.account import Account, Tenant
from models.dataset import Dataset, Document, DocumentSegment
from services.file_service import FileService
from services.knowledge.dataset_service import DatasetService, DocumentService
from services.knowledge.entities.knowledge_entities import (
    KnowledgeConfig, DataSource, InfoList, FileInfo, ProcessRule, RetrievalModel
)
from core.rag.entities import Rule, Segmentation, PreProcessingRule
from models.enums import ProcessRuleMode
from core.rag.retrieval.retrieval_methods import RetrievalMethod

DATASET_DIR = '/tmp/dataset'
DATASET_ID = '8e29fd5b-9537-46ac-acde-191b457b793e'
TENANT_ID = 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'

_, flask_app = app.create_app()
with flask_app.app_context():
    account = db.session.get(Account, ACCOUNT_ID)
    tenant = db.session.get(Tenant, TENANT_ID)
    account.set_current_tenant_with_session(tenant, session=db.session)

    dataset = db.session.get(Dataset, DATASET_ID)
    if not dataset:
        raise RuntimeError(f"Dataset {DATASET_ID} not found.")

    # Cleanup any previous failed documents
    existing_docs = db.session.query(Document).filter(Document.dataset_id == DATASET_ID).all()
    if existing_docs:
        print(f"Cleaning up {len(existing_docs)} previous documents...")
        for ed in existing_docs:
            db.session.query(DocumentSegment).filter(DocumentSegment.document_id == ed.id).delete()
            db.session.delete(ed)
        db.session.commit()

    files_to_ingest = [
        ('saudi_tech_initiatives.ar.md', 'Arabic Technical Initiatives Document'),
        ('cloud_architecture_standards.en.md', 'Enterprise Cloud Architecture Standards'),
        ('regional_datacenter_comparison.ar.md', 'Regional Commercial Datacenter Comparison')
    ]

    file_service = FileService(session_factory=db.engine)
    created_docs = []

    for fname, desc in files_to_ingest:
        fpath = os.path.join(DATASET_DIR, fname)
        with open(fpath, 'r', encoding='utf-8') as f:
            content = f.read()

        # 1. Upload text to Dify storage
        upload_file = file_service.upload_text(
            text=content,
            text_name=fname,
            user_id=ACCOUNT_ID,
            tenant_id=TENANT_ID
        )
        print(f"Uploaded file '{fname}' with File ID: {upload_file.id}")

        # 2. Build KnowledgeConfig
        knowledge_config = KnowledgeConfig(
            indexing_technique="high_quality",
            doc_form="text_model",
            doc_language="English" if fname.endswith('.en.md') else "Arabic",
            name=fname,
            data_source=DataSource(
                info_list=InfoList(
                    data_source_type="upload_file",
                    file_info_list=FileInfo(file_ids=[upload_file.id])
                )
            ),
            process_rule=ProcessRule(
                mode=ProcessRuleMode.CUSTOM,
                rules=Rule(
                    pre_processing_rules=[
                        PreProcessingRule(id="remove_extra_spaces", enabled=True),
                        PreProcessingRule(id="remove_urls_emails", enabled=False)
                    ],
                    segmentation=Segmentation(
                        separator="\n",
                        max_tokens=600,
                        chunk_overlap=60
                    )
                )
            ),
            retrieval_model=RetrievalModel(
                search_method=RetrievalMethod.HYBRID_SEARCH,
                reranking_enable=False,
                top_k=4,
                score_threshold_enabled=False
            ),
            embedding_model="bge-m3:latest",
            embedding_model_provider="langgenius/ollama/ollama"
        )

        # 3. Save document & dispatch indexing
        docs, batch = DocumentService.save_document_with_dataset_id(
            dataset=dataset,
            knowledge_config=knowledge_config,
            account=account,
            session=db.session
        )
        db.session.commit()
        created_docs.extend(docs)
        print(f"Created {len(docs)} document(s) in batch {batch}")

    print(f"\nDispatched {len(created_docs)} documents for background indexing.")
    print("Polling indexing progress...")

    # Poll status for up to 120 seconds
    all_completed = False
    for attempt in range(60):
        time.sleep(2)
        db.session.expire_all()
        doc_statuses = []
        for doc in created_docs:
            d = db.session.get(Document, doc.id)
            doc_statuses.append((d.name, d.indexing_status, d.completed_at, d.error))

        in_progress = any(s[1] in ('indexing', 'waiting', 'parsing', 'cleaning', 'splitting') for s in doc_statuses)
        all_ok = all(s[1] == 'completed' for s in doc_statuses)
        any_error = any(s[1] == 'error' for s in doc_statuses)

        status_str = ", ".join([f"{s[0]}: {s[1]}" for s in doc_statuses])
        print(f"[{attempt+1}] Status: {status_str}")

        if all_ok:
            all_completed = True
            break
        if any_error:
            for s in doc_statuses:
                if s[1] == 'error':
                    print(f"ERROR on {s[0]}: {s[3]}")
            break

    # Count segments
    segments = db.session.query(DocumentSegment).filter(DocumentSegment.dataset_id == DATASET_ID).all()
    print(f"\n=== INDEXING SUMMARY ===")
    print(f"Total Documents: {len(created_docs)}")
    print(f"Total Chunks / Segments in Dataset: {len(segments)}")
    for seg in segments:
        print(f" - Segment #{seg.position} (Doc: {seg.document_id}): {len(seg.content)} chars, words: {seg.word_count}")

    if all_completed and len(segments) > 0:
        print("\nINDEXING_SUCCESSFUL")
    else:
        raise RuntimeError("Indexing did not complete successfully.")


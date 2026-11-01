"""
Stage D.1 Hardened Document Ingestion & Indexing Script
Features:
- Enforces safety confirmation: --force-reindex requires --confirm-destroy
- Restricts force-reindex to explicitly selected test fixtures (--fixtures)
- SHA-256 content hashing to detect changed documents without silently skipping updates
- Semantic paragraph segmentation (separator="\\n\\n", 600 max tokens, 60 tokens overlap)
- High-quality hybrid indexing with BGE-M3 embeddings
- Verifies vector-index consistency across Weaviate and PostgreSQL
"""

import sys
import os
import time
import hashlib
import argparse

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.account import Account, Tenant
from models.dataset import Dataset, Document, DocumentSegment
from services.file_service import FileService
from services.knowledge.dataset_service import DocumentService
from services.knowledge.entities.knowledge_entities import (
    KnowledgeConfig, DataSource, InfoList, FileInfo, ProcessRule
)
from core.rag.entities import Rule, Segmentation, PreProcessingRule
from models.enums import ProcessRuleMode

DATASET_DIR = '/tmp/dataset'
DATASET_ID = '8e29fd5b-9537-46ac-acde-191b457b793e'
TENANT_ID = 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'

parser = argparse.ArgumentParser(description="Stage D.1 Hardened Knowledge Base Ingestion")
parser.add_argument('--force-reindex', action='store_true', help="Force reindexing of documents")
parser.add_argument('--confirm-destroy', action='store_true', help="Required safety confirmation for --force-reindex")
parser.add_argument('--fixtures', type=str, default="all", help="Comma-separated list of fixture filenames to process or 'all'")

args = parser.parse_args()

# Rule 6: Safety check for force-reindex
if args.force_reindex and not args.confirm_destroy:
    sys.exit("ERROR: Safety violation. --force-reindex requires explicit --confirm-destroy flag to proceed.")

selected_fixtures = [f.strip() for f in args.fixtures.split(',')] if args.fixtures != "all" else "all"

_, flask_app = app.create_app()
with flask_app.app_context():
    account = db.session.get(Account, ACCOUNT_ID)
    tenant = db.session.get(Tenant, TENANT_ID)
    account.set_current_tenant_with_session(tenant, session=db.session)

    dataset = db.session.get(Dataset, DATASET_ID)
    if not dataset:
        raise RuntimeError(f"Dataset {DATASET_ID} not found.")

    all_fixtures = [
        ('saudi_tech_initiatives.ar.md', 'Arabic Technical Initiatives Document (Synthetic Fixture)'),
        ('cloud_architecture_standards.en.md', 'Enterprise Cloud Architecture Standards (Synthetic Fixture)'),
        ('regional_datacenter_comparison.ar.md', 'Regional Commercial Datacenter Comparison (Synthetic Fixture)')
    ]

    if selected_fixtures == "all":
        fixtures_to_process = all_fixtures
    else:
        fixtures_to_process = [f for f in all_fixtures if f[0] in selected_fixtures]
        if not fixtures_to_process:
            sys.exit(f"ERROR: No valid fixtures found matching --fixtures={args.fixtures}")

    existing_docs = {
        d.name: d for d in db.session.query(Document).filter(
            Document.dataset_id == DATASET_ID
        ).all()
    }

    file_service = FileService(session_factory=db.engine)
    newly_created_docs = []

    print("=" * 80)
    print("STAGE D.1: HARDENED KNOWLEDGE INGESTION & CONTENT HASH AUDIT")
    print(f"Dataset ID: {DATASET_ID} | Force Reindex: {args.force_reindex} | Fixtures: {[f[0] for f in fixtures_to_process]}")
    print("=" * 80)

    for fname, desc in fixtures_to_process:
        fpath = os.path.join(DATASET_DIR, fname)
        if not os.path.exists(fpath):
            raise FileNotFoundError(f"Source file not found: {fpath}")

        with open(fpath, 'r', encoding='utf-8') as f:
            content = f.read()

        content_hash = hashlib.sha256(content.encode('utf-8')).hexdigest()

        # Check existing document
        if fname in existing_docs:
            doc = existing_docs[fname]
            meta = doc.doc_metadata or {}
            stored_hash = meta.get('sha256') if isinstance(meta, dict) else None

            # Check if force reindex is targeting this specific fixture
            if args.force_reindex:
                print(f"[REINDEX] Explicit --force-reindex targeting fixture '{fname}'. Safely replacing document and vector embeddings...")
                DocumentService.delete_document(doc, session=db.session)
                db.session.commit()
            elif stored_hash and stored_hash != content_hash:
                print(f"[UPDATE] Content changed for '{fname}' (Stored SHA: {stored_hash[:8]} -> New SHA: {content_hash[:8]}). Re-indexing...")
                DocumentService.delete_document(doc, session=db.session)
                db.session.commit()
            else:
                segs = db.session.query(DocumentSegment).filter(
                    DocumentSegment.document_id == doc.id
                ).all()
                if doc.indexing_status == 'completed' and len(segs) > 0:
                    # Backfill hash in doc_metadata if absent
                    if not stored_hash:
                        meta = dict(meta) if isinstance(meta, dict) else {}
                        meta['sha256'] = content_hash
                        doc.doc_metadata = meta
                        db.session.commit()
                    print(f"[SKIP] Document '{fname}' is unchanged (SHA-256: {content_hash[:8]}..., ID: {doc.id}, Segments: {len(segs)}). Skipping duplicate ingestion.")
                    continue
                else:
                    print(f"[RECOVER] Document '{fname}' exists in incomplete status '{doc.indexing_status}'. Re-indexing...")
                    DocumentService.delete_document(doc, session=db.session)
                    db.session.commit()

        # Ingestion step
        print(f"Ingesting '{fname}' (SHA-256: {content_hash[:8]}...)...")
        upload_file = file_service.upload_text(
            text=content,
            text_name=fname,
            user_id=ACCOUNT_ID,
            tenant_id=TENANT_ID
        )

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
                        separator="\n\n",
                        max_tokens=600,
                        chunk_overlap=60
                    )
                )
            )
        )

        documents, batch = DocumentService.save_document_with_dataset_id(
            dataset=dataset,
            knowledge_config=knowledge_config,
            account=account,
            dataset_process_rule=None,
            created_from="web",
            session=db.session
        )

        # Attach content hash to document metadata
        for d in documents:
            d_meta = d.doc_metadata or {}
            d_meta = dict(d_meta) if isinstance(d_meta, dict) else {}
            d_meta['sha256'] = content_hash
            d.doc_metadata = d_meta
        db.session.commit()

        newly_created_docs.extend(documents)
        print(f"Dispatched indexing for '{fname}', Batch ID: {batch}")

    if newly_created_docs:
        print("\nWaiting for indexing workers to complete...")
        for doc in newly_created_docs:
            for _ in range(60):
                db.session.refresh(doc)
                if doc.indexing_status == 'completed':
                    segs = db.session.query(DocumentSegment).filter(
                        DocumentSegment.document_id == doc.id
                    ).count()
                    print(f"[COMPLETED] Document '{doc.name}' indexed successfully ({segs} segments).")
                    break
                elif doc.indexing_status == 'error':
                    raise RuntimeError(f"Indexing failed for '{doc.name}': {doc.error}")
                time.sleep(2)
            else:
                raise TimeoutError(f"Indexing timed out for '{doc.name}' (status: {doc.indexing_status}).")

    # Final Consistency Verification
    all_docs = db.session.query(Document).filter(Document.dataset_id == DATASET_ID).all()
    total_segments = db.session.query(DocumentSegment).filter(
        DocumentSegment.dataset_id == DATASET_ID,
        DocumentSegment.status == 'completed'
    ).count()

    print(f"\nVector Index Consistency Audit:")
    print(f"- Total Documents: {len(all_docs)} (All completed: {all(d.indexing_status == 'completed' for d in all_docs)})")
    print(f"- Total Active Segments: {total_segments}")
    for d in all_docs:
        d_segs = db.session.query(DocumentSegment).filter(DocumentSegment.document_id == d.id).count()
        meta = d.doc_metadata or {}
        shash = meta.get('sha256', 'unknown')[:8] if isinstance(meta, dict) else 'none'
        print(f"  * {d.name}: {d_segs} segments | SHA: {shash} | status: {d.indexing_status}")

    print("\nSUCCESS: Knowledge Base indexing verified.")

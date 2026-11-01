"""
Stage E Held-Out Dataset Ingestion & App Linking Script
Features:
- Creates or retrieves dedicated 'Stage E Held-Out Knowledge Base'
- Preserves existing production dataset (8e29fd5b-9537-46ac-acde-191b457b793e) completely intact
- Indexes 3 new held-out fixtures with BGE-M3 hybrid search
- Links held-out dataset to both Chatbot and Chatflow applications
- Verifies document indexing status and segment counts
"""

import sys
import os
import time
import hashlib
import json

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.account import Account, Tenant
from models.dataset import Dataset, Document, DocumentSegment, AppDatasetJoin
from models.model import App
from models.workflow import Workflow
from services.file_service import FileService
from services.knowledge.dataset_service import DatasetService, DocumentService
from services.workflow_service import WorkflowService
from services.knowledge.entities.knowledge_entities import (
    KnowledgeConfig, DataSource, InfoList, FileInfo, ProcessRule
)
from core.rag.entities import Rule, Segmentation, PreProcessingRule
from models.enums import ProcessRuleMode

DATASET_DIR = '/tmp/held_out_dataset'
TENANT_ID = 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'
PROD_DATASET_ID = '8e29fd5b-9537-46ac-acde-191b457b793e'
CHATBOT_NAME = 'Local Bilingual RAG Assistant'
CHATFLOW_NAME = 'Local Bilingual RAG Chatflow'

def compute_sha256(filepath):
    hasher = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()

def main():
    print("=" * 80)
    print("STAGE E: HELD-OUT DATASET INGESTION & APP LINKING")
    print("=" * 80)

    _, flask_app = app.create_app()
    with flask_app.app_context():
        account = db.session.get(Account, ACCOUNT_ID)
        tenant = db.session.get(Tenant, TENANT_ID)
        account.set_current_tenant_with_session(tenant, session=db.session)

        # 1. Find or create held-out dataset
        held_out_ds = db.session.query(Dataset).filter(
            Dataset.tenant_id == TENANT_ID,
            Dataset.name == "Stage E Held-Out Knowledge Base"
        ).first()

        if not held_out_ds:
            print("Creating new Dataset: 'Stage E Held-Out Knowledge Base'...")
            held_out_ds = DatasetService.create_empty_dataset(
                tenant_id=TENANT_ID,
                name="Stage E Held-Out Knowledge Base",
                description="Held-out acceptance evaluation dataset for independent verification in Stage E",
                indexing_technique="high_quality",
                account=account,
                permission="only_me",
                provider="vendor",
                embedding_model_provider="langgenius/ollama/ollama",
                embedding_model_name="bge-m3:latest",
                session=db.session
            )
            # Set hybrid retrieval model
            held_out_ds.retrieval_model = {
                'top_k': 4,
                'search_method': 'hybrid_search',
                'reranking_enable': False,
                'score_threshold_enabled': False
            }
            db.session.commit()
            print(f"Created Dataset ID: {held_out_ds.id}")
        else:
            print(f"Found existing Held-Out Dataset ID: {held_out_ds.id}")

        dataset_id = held_out_ds.id

        # 2. Ingest held-out fixtures
        fixtures = [
            ('national_smart_grid_initiative.ar.md', 'National Smart Grid Automation Initiative (Held-Out Fixture)'),
            ('quantum_resilient_cryptography.en.md', 'Quantum-Resilient Cryptographic Architecture (Held-Out Fixture)'),
            ('commercial_energy_solutions.ar.md', 'Commercial Solar Solutions Ambiguity Report (Held-Out Fixture)')
        ]

        file_service = FileService(session_factory=db.engine)
        existing_docs = {
            d.name: d for d in db.session.query(Document).filter(
                Document.dataset_id == dataset_id
            ).all()
        }

        for filename, desc in fixtures:
            filepath = os.path.join(DATASET_DIR, filename)
            if not os.path.exists(filepath):
                print(f"ERROR: Fixture not found at {filepath}")
                continue

            current_hash = compute_sha256(filepath)
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            existing_doc = existing_docs.get(filename)
            if existing_doc and existing_doc.indexing_status == 'completed':
                doc_hash = (existing_doc.doc_metadata or {}).get('sha256')
                if doc_hash == current_hash:
                    print(f"[SKIP] Document '{filename}' is unchanged and completed (SHA-256: {current_hash[:8]}...).")
                    continue
                else:
                    print(f"[UPDATE] Document '{filename}' hash changed. Deleting old document {existing_doc.id}...")
                    DocumentService.delete_document(existing_doc, session=db.session)
                    db.session.commit()

            print(f"\n[INGEST] Uploading '{filename}' ({len(content)} chars, SHA: {current_hash[:8]})...")
            upload_file = file_service.upload_text(
                text=content,
                text_name=filename,
                user_id=ACCOUNT_ID,
                tenant_id=TENANT_ID
            )

            knowledge_config = KnowledgeConfig(
                indexing_technique="high_quality",
                doc_form="text_model",
                doc_language="English" if filename.endswith('.en.md') else "Arabic",
                name=filename,
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
                dataset=held_out_ds,
                knowledge_config=knowledge_config,
                account=account,
                dataset_process_rule=None,
                created_from="web",
                session=db.session
            )
            created_doc = documents[0]
            created_doc.doc_metadata = {'sha256': current_hash, 'description': desc}
            db.session.commit()
            print(f"Created Document: '{created_doc.name}' (ID: {created_doc.id}, Batch: {batch})")

            # Poll for indexing completion
            print(f"Waiting for indexing of '{filename}'...")
            t0 = time.time()
            while time.time() - t0 < 60:
                db.session.refresh(created_doc)
                status = created_doc.indexing_status
                if status == 'completed':
                    seg_count = db.session.query(DocumentSegment).filter(
                        DocumentSegment.document_id == created_doc.id,
                        DocumentSegment.status == 'completed'
                    ).count()
                    print(f"  [COMPLETED] '{filename}' indexed into {seg_count} segments in {time.time()-t0:.1f}s.")
                    break
                elif status in ('error', 'failed'):
                    print(f"  [ERROR] Document indexing failed: {created_doc.error}")
                    break
                time.sleep(1.0)

        # 3. Link held-out dataset to Chatbot
        cb = db.session.query(App).filter(App.name == CHATBOT_NAME).first()
        if cb:
            join = db.session.query(AppDatasetJoin).filter(
                AppDatasetJoin.app_id == cb.id,
                AppDatasetJoin.dataset_id == dataset_id
            ).first()
            if not join:
                db.session.add(AppDatasetJoin(app_id=cb.id, dataset_id=dataset_id))
                db.session.commit()
                print(f"[LINK] Added Held-Out Dataset to Chatbot '{CHATBOT_NAME}'.")
            else:
                print(f"[LINK] Chatbot '{CHATBOT_NAME}' already linked to Held-Out Dataset.")

        # 4. Link held-out dataset to Chatflow
        cf = db.session.query(App).filter(App.name == CHATFLOW_NAME).first()
        if cf:
            workflow_service = WorkflowService()
            draft = workflow_service.get_draft_workflow(app_model=cf, session=db.session)
            if draft:
                graph = draft.graph_dict or {}
                nodes = graph.get('nodes', [])
                updated = False
                for node in nodes:
                    if node.get('data', {}).get('type') == 'knowledge-retrieval':
                        curr_ids = node['data'].get('dataset_ids', [])
                        if dataset_id not in curr_ids:
                            curr_ids.append(dataset_id)
                            node['data']['dataset_ids'] = curr_ids
                            updated = True
                            print(f"[LINK] Updated Chatflow retrieval node datasets: {curr_ids}")

                if updated:
                    workflow_service.sync_draft_workflow(
                        app_model=cf,
                        graph=graph,
                        features=draft.features_dict,
                        unique_hash=draft.unique_hash,
                        account=account,
                        environment_variables=[],
                        conversation_variables=[],
                        session=db.session,
                        commit=True
                    )
                    pub_wf = workflow_service.publish_workflow(
                        session=db.session,
                        app_model=cf,
                        account=account,
                        marked_name="v1.1.0",
                        marked_comment="Stage E held-out dataset integration"
                    )
                    cf.workflow_id = pub_wf.id
                    db.session.commit()
                    print(f"[LINK] Published updated Chatflow with dual datasets (Version: {pub_wf.version}).")
                else:
                    print(f"[LINK] Chatflow already includes Held-Out Dataset in retrieval node.")

        # Final Verification
        docs = db.session.query(Document).filter(Document.dataset_id == dataset_id).all()
        segs = db.session.query(DocumentSegment).filter(
            DocumentSegment.dataset_id == dataset_id,
            DocumentSegment.status == 'completed'
        ).all()
        print(f"\nHELD-OUT DATASET SUMMARY: ID: {dataset_id} | Docs: {len(docs)} | Completed Segments: {len(segs)}")

if __name__ == '__main__':
    main()

"""
Stage E.1 Sealed Dataset Ingestion & App Linking Script
Features:
- Creates or retrieves dedicated 'Stage E.1 Sealed Knowledge Base'
- Preserves all prior datasets (Stage D and Stage E) completely intact
- Indexes 3 new sealed fixtures with BGE-M3 hybrid search
- Links sealed dataset to both Chatbot and Chatflow applications
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
from models.model import App, AppModelConfig
from models.workflow import Workflow
from services.file_service import FileService
from services.knowledge.dataset_service import DatasetService, DocumentService
from services.workflow_service import WorkflowService
from services.knowledge.entities.knowledge_entities import (
    KnowledgeConfig, DataSource, InfoList, FileInfo, ProcessRule
)
from core.rag.entities import Rule, Segmentation, PreProcessingRule
from models.enums import ProcessRuleMode

DATASET_DIR = '/tmp/sealed_dataset'
TENANT_ID = 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'
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
    print("STAGE E.1: SEALED DATASET INGESTION & APP LINKING")
    print("=" * 80)

    _, flask_app = app.create_app()
    with flask_app.app_context():
        account = db.session.get(Account, ACCOUNT_ID)
        tenant = db.session.get(Tenant, TENANT_ID)
        account.set_current_tenant_with_session(tenant, session=db.session)

        # 1. Find or create sealed dataset
        sealed_ds = db.session.query(Dataset).filter(
            Dataset.tenant_id == TENANT_ID,
            Dataset.name == "Stage E.1 Sealed Knowledge Base"
        ).first()

        if not sealed_ds:
            print("Creating new Dataset: 'Stage E.1 Sealed Knowledge Base'...")
            sealed_ds = DatasetService.create_empty_dataset(
                tenant_id=TENANT_ID,
                name="Stage E.1 Sealed Knowledge Base",
                description="Sealed acceptance evaluation dataset for independent verification in Stage E.1",
                indexing_technique="high_quality",
                account=account,
                permission="only_me",
                provider="vendor",
                embedding_model_provider="langgenius/ollama/ollama",
                embedding_model_name="bge-m3:latest",
                session=db.session
            )
            sealed_ds.retrieval_model = {
                'top_k': 6,
                'search_method': 'hybrid_search',
                'reranking_enable': False,
                'score_threshold_enabled': False
            }
            db.session.commit()
            print(f"Created Dataset ID: {sealed_ds.id}")
        else:
            print(f"Found existing Sealed Dataset ID: {sealed_ds.id}")

        dataset_id = sealed_ds.id

        # 2. Ingest sealed fixtures
        fixtures = [
            ('sovereign_quantum_satellite_communications.ar.md', 'Sovereign Quantum Satellite Communications (Sealed Fixture)'),
            ('autonomous_edge_telemetry_protocols.en.md', 'Autonomous Edge Telemetry Protocols (Sealed Fixture)'),
            ('municipal_smart_water_networks.ar.md', 'Municipal Smart Water Networks (Sealed Fixture)')
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
            if existing_doc:
                if existing_doc.indexing_status == 'completed':
                    doc_hash = (existing_doc.doc_metadata or {}).get('sha256')
                    if doc_hash == current_hash:
                        print(f"[SKIP] Document '{filename}' is unchanged and completed (SHA-256: {current_hash[:8]}...).")
                        continue
                print(f"[CLEANUP] Deleting incomplete or stale document {existing_doc.id} ('{filename}')...")
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

            created_docs, batch = DocumentService.save_document_with_dataset_id(
                dataset=sealed_ds,
                knowledge_config=knowledge_config,
                account=account,
                dataset_process_rule=None,
                created_from="web",
                session=db.session
            )
            created_doc = created_docs[0]
            created_doc.doc_metadata = {"sha256": current_hash, "description": desc}
            db.session.commit()

            print(f"  Created document {created_doc.id} (batch {batch}). Waiting for indexing...")
            for attempt in range(60):
                db.session.refresh(created_doc)
                status = created_doc.indexing_status
                if status == 'completed':
                    segs = db.session.query(DocumentSegment).filter(
                        DocumentSegment.document_id == created_doc.id
                    ).count()
                    print(f"  [OK] Document '{filename}' indexed successfully ({segs} segments).")
                    break
                elif status in ('error', 'failed'):
                    print(f"  [ERROR] Document indexing failed: {created_doc.error}")
                    break
                time.sleep(1.0)

        # 3. Link sealed dataset to Chatbot
        cb = db.session.query(App).filter(App.name == CHATBOT_NAME).first()
        if cb:
            join = db.session.query(AppDatasetJoin).filter(
                AppDatasetJoin.app_id == cb.id,
                AppDatasetJoin.dataset_id == dataset_id
            ).first()
            if not join:
                db.session.add(AppDatasetJoin(app_id=cb.id, dataset_id=dataset_id))
                db.session.commit()
                print(f"[LINK] Added AppDatasetJoin for Chatbot '{CHATBOT_NAME}'.")

            # Also update app_model_config.dataset_configs
            cfg = db.session.query(AppModelConfig).filter(AppModelConfig.id == cb.app_model_config_id).first()
            if cfg and cfg.dataset_configs:
                configs = json.loads(cfg.dataset_configs) if isinstance(cfg.dataset_configs, str) else cfg.dataset_configs
                ds_list = configs.get('datasets', {}).get('datasets', [])
                existing_ids = [d.get('dataset', {}).get('id') for d in ds_list]
                if dataset_id not in existing_ids:
                    ds_list.append({"dataset": {"id": dataset_id, "enabled": True}})
                    configs['datasets']['datasets'] = ds_list
                    cfg.dataset_configs = json.dumps(configs) if isinstance(cfg.dataset_configs, str) else configs
                    from sqlalchemy.orm.attributes import flag_modified
                    flag_modified(cfg, "dataset_configs")
                    db.session.commit()
                    print(f"[LINK] Updated Chatbot model config datasets: {[d['dataset']['id'] for d in ds_list]}")

        # 4. Link sealed dataset to Chatflow
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
                            # Increase top_k to 10 to comfortably retrieve from all 3 datasets
                            node['data']['multiple_retrieval_config'] = {
                                'top_k': 10,
                                'score_threshold': None,
                                'reranking_enable': False,
                                'reranking_mode': 'weighted_score'
                            }
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
                        marked_name="v1.2.0",
                        marked_comment="Stage E.1 sealed dataset integration"
                    )
                    cf.workflow_id = pub_wf.id
                    db.session.commit()
                    print(f"[LINK] Published updated Chatflow with sealed dataset (Version: {pub_wf.version}).")
                else:
                    print(f"[LINK] Chatflow already includes Sealed Dataset in retrieval node.")

        # Final Verification
        docs = db.session.query(Document).filter(Document.dataset_id == dataset_id).all()
        segs = db.session.query(DocumentSegment).filter(
            DocumentSegment.dataset_id == dataset_id,
            DocumentSegment.status == 'completed'
        ).all()
        print(f"\nSEALED DATASET SUMMARY: ID: {dataset_id} | Docs: {len(docs)} | Completed Segments: {len(segs)}")

if __name__ == '__main__':
    main()

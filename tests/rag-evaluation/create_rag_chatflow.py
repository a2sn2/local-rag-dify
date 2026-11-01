"""
Stage D.1 — Create and Configure Local Bilingual RAG Chatflow (Advanced-Chat) Application in Dify
"""

import sys
import os
import json
import uuid

if '/app/api' not in sys.path:
    sys.path.insert(0, '/app/api')

import app
from extensions.ext_database import db
from models.account import Account, Tenant
from models.model import App, AppMode, ApiToken
from models.dataset import Dataset
from models.workflow import Workflow, WorkflowType
from models.enums import ApiTokenType
from services.app_service import AppService
from services.entities.app_entities import CreateAppParams
from services.workflow_service import WorkflowService
from services.app_dsl_service import AppDslService
from libs.datetime_utils import naive_utc_now

TENANT_ID = 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'
DATASET_ID = '8e29fd5b-9537-46ac-acde-191b457b793e'
APP_NAME = 'Local Bilingual RAG Chatflow'

SYSTEM_PROMPT = """أنت مساعد تقني مؤسسي ذكي ثنائي اللغة (العربية والإنجليزية) متخصص في الإجابة على الاستفسارات الفنية بدقة وموثوقية عالية استناداً حصراً إلى الوثائق التقنية المرفقة.

القواعد الصارمة الملزمة:
1. الالتزام المطلق بالسياق (Strict Grounding): اعتمد حصراً وبشكل صارم على المعلومات والحقائق الواردة في نصوص الوثائق المرفقة (Context). لا تقدم أي إجابة بناءً على معرفتك الخارجية المسبقة أو تخميناتك.
2. منع الهلوسة الصارم (Anti-Hallucination): يُحظر تماماً التخمين، أو افتراض حقائق غير موجودة، أو تأليف أي أرقام، ميزانيات، جداول رحلات، تواريخ، أو مواصفات غير مذكورة نصاً.
3. التوثيق والاقتباس الداخلي الصريح (Inline Citations):
   - يجب في نهاية كل معلومة أو إجابة كتابة اسم ملف الوثيقة الفعلي وعنوان القسم المقتبس منه بدقة، مثل: [saudi_tech_initiatives.ar.md, قسم 1] أو [cloud_architecture_standards.en.md, Section 2].
   - تحذير صارم: يُحظر نهائياً وبشكل قاطع استخدام نصوص بديلة (Placeholders) أو عبارات عامة مثل "[اسم الوثيقة]" أو "[رقم الفقرة]" أو "[Document Name]" أو "[Section X]" أو "[السياق]". اكتب دائماً اسم الملف الحقيقي من السياق.
4. الامتناع الصريح في حال عدم التوفر أو الاستفسارات المضللة (Explicit Abstention):
   - إذا كان سؤال المستخدم يتعلق بموضوع غير مدعوم، أو حقائق غير موجودة، أو يستند إلى وثيقة مزيفة/غير مرفقة (مثل تقرير دبي، أو ميزانية غير مذكورة، أو رحلات طيران، أو إحصائيات لم ترد)، أو كان استفساراً مضللاً أو مقارنة مع مصادر غير موجودة، فيجب عليك الامتناع عن الإجابة فوراً وكتابة النص التالي حرفياً:
   "المعلومة المطلوبة غير متوفرة في الوثائق المرفقة.
The requested information is not available in the provided documents."
   لا تحاول تخمين أو تقديم إجابة جزئية غير موثقة على الإطلاق.
5. الدقة اللغوية والاصطلاحية: أجب بنفس لغة السؤال (العربية أو الإنجليزية). حافظ على دقة المصطلحات والوحدات بدقة (مثل الرموز البرمجية، ووحدات القياس كالرموز Tokens بدلاً من الكلمات Words إن نصت الوثيقة على ذلك).

السياق المرفق:
{{#context#}}
"""

ABSTENTION_MESSAGE = (
    "المعلومة المطلوبة غير متوفرة في الوثائق المرفقة.\n\n"
    "The requested information is not available in the provided documents."
)

_, flask_app = app.create_app()
with flask_app.app_context():
    account = db.session.get(Account, ACCOUNT_ID)
    tenant = db.session.get(Tenant, TENANT_ID)
    account.set_current_tenant_with_session(tenant, session=db.session)

    # 1. Check if Chatflow App already exists
    existing_app = db.session.query(App).filter(
        App.tenant_id == TENANT_ID,
        App.name == APP_NAME
    ).first()

    if not existing_app:
        print(f"Creating new Advanced Chat app '{APP_NAME}'...")
        params = CreateAppParams(
            name=APP_NAME,
            description="Local bilingual Arabic/English grounded RAG Chatflow featuring visual node graph with explicit evidence validation and abstention branch.",
            mode=AppMode.ADVANCED_CHAT.value,
            agent_role="",
            icon_type="emoji",
            icon="⚡",
            icon_background="#D1FADF",
            api_rph=0,
            api_rpm=0,
            max_active_requests=None
        )
        app_model = AppService().create_app(
            tenant_id=TENANT_ID,
            params=params,
            account=account,
            session=db.session
        )
        print(f"App created successfully with ID: {app_model.id}")
    else:
        app_model = existing_app
        print(f"Found existing app with ID: {app_model.id}")

    # 2. Build the visual Chatflow node graph:
    # START -> Knowledge Retrieval -> Evidence Check -> LLM -> Answer (Grounded)
    #                                                -> Answer (Abstention)
    graph = {
        "nodes": [
            {
                "id": "start",
                "type": "custom",
                "data": {
                    "type": "start",
                    "title": "Start",
                    "variables": []
                },
                "position": {"x": 80, "y": 282},
                "targetPosition": "left",
                "sourcePosition": "right"
            },
            {
                "id": "retrieval",
                "type": "custom",
                "data": {
                    "type": "knowledge-retrieval",
                    "title": "Knowledge Retrieval",
                    "query_variable_selector": ["sys", "query"],
                    "dataset_ids": [DATASET_ID],
                    "retrieval_mode": "single",
                    "single_retrieval_config": {
                        "model": {
                            "provider": "langgenius/ollama/ollama",
                            "name": "qwen3.5:4b",
                            "mode": "chat",
                            "completion_params": {}
                        }
                    },
                    "multiple_retrieval_config": {
                        "top_k": 6,
                        "score_threshold": None,
                        "reranking_enable": False,
                        "reranking_mode": "weighted_score"
                    }
                },
                "position": {"x": 380, "y": 282},
                "targetPosition": "left",
                "sourcePosition": "right"
            },
            {
                "id": "evidence_check",
                "type": "custom",
                "data": {
                    "type": "if-else",
                    "title": "Evidence Check",
                    "logical_operator": "and",
                    "conditions": [
                        {
                            "variable_selector": ["retrieval", "result"],
                            "comparison_operator": "not empty",
                            "value": ""
                        }
                    ],
                    "cases": [
                        {
                            "case_id": "true",
                            "logical_operator": "and",
                            "conditions": [
                                {
                                    "variable_selector": ["retrieval", "result"],
                                    "comparison_operator": "not empty",
                                    "value": ""
                                }
                            ]
                        }
                    ]
                },
                "position": {"x": 680, "y": 282},
                "targetPosition": "left",
                "sourcePosition": "right"
            },
            {
                "id": "llm",
                "type": "custom",
                "data": {
                    "type": "llm",
                    "title": "LLM (Qwen3.5 4B)",
                    "model": {
                        "provider": "langgenius/ollama/ollama",
                        "name": "qwen3.5:4b",
                        "mode": "chat",
                        "completion_params": {
                            "temperature": 0.1,
                            "max_tokens": 512,
                            "top_p": 0.9,
                            "stop": [],
                            "think": False
                        }
                    },
                    "prompt_template": [
                        {
                            "role": "system",
                            "text": SYSTEM_PROMPT
                        },
                        {
                            "role": "user",
                            "text": "{{#sys.query#}}"
                        }
                    ],
                    "context": {
                        "enabled": True,
                        "variable_selector": ["retrieval", "result"]
                    },
                    "vision": {
                        "enabled": False
                    },
                    "memory": {
                        "window": {
                            "enabled": False,
                            "size": 10
                        },
                        "query_prompt_template": "{{#sys.query#}}"
                    }
                },
                "position": {"x": 980, "y": 180},
                "targetPosition": "left",
                "sourcePosition": "right"
            },
            {
                "id": "answer_grounded",
                "type": "custom",
                "data": {
                    "type": "answer",
                    "title": "Answer (Grounded)",
                    "variables": [],
                    "answer": "{{#llm.text#}}"
                },
                "position": {"x": 1280, "y": 180},
                "targetPosition": "left",
                "sourcePosition": "right"
            },
            {
                "id": "answer_abstain",
                "type": "custom",
                "data": {
                    "type": "answer",
                    "title": "Answer (Abstention)",
                    "variables": [],
                    "answer": ABSTENTION_MESSAGE
                },
                "position": {"x": 980, "y": 420},
                "targetPosition": "left",
                "sourcePosition": "right"
            }
        ],
        "edges": [
            {
                "id": "start-retrieval",
                "source": "start",
                "sourceHandle": "source",
                "target": "retrieval",
                "targetHandle": "target"
            },
            {
                "id": "retrieval-evidence_check",
                "source": "retrieval",
                "sourceHandle": "source",
                "target": "evidence_check",
                "targetHandle": "target"
            },
            {
                "id": "evidence_check-llm",
                "source": "evidence_check",
                "sourceHandle": "true",
                "target": "llm",
                "targetHandle": "target"
            },
            {
                "id": "llm-answer_grounded",
                "source": "llm",
                "sourceHandle": "source",
                "target": "answer_grounded",
                "targetHandle": "target"
            },
            {
                "id": "evidence_check-answer_abstain",
                "source": "evidence_check",
                "sourceHandle": "false",
                "target": "answer_abstain",
                "targetHandle": "target"
            }
        ]
    }

    features = {
        "retriever_resource": {
            "enabled": True
        },
        "suggested_questions_after_answer": {
            "enabled": False
        },
        "file_upload": {
            "enabled": False
        }
    }

    # 3. Validate and sync draft workflow
    workflow_service = WorkflowService()
    workflow_service.validate_graph_structure(graph=graph)
    print("Graph structure validated successfully.")

    existing_draft = workflow_service.get_draft_workflow(app_model=app_model, session=db.session)
    draft_hash = existing_draft.unique_hash if existing_draft else None

    draft_workflow = workflow_service.sync_draft_workflow(
        app_model=app_model,
        graph=graph,
        features=features,
        unique_hash=draft_hash,
        account=account,
        environment_variables=[],
        conversation_variables=[],
        session=db.session,
        commit=True
    )
    print(f"Draft workflow synced successfully (Workflow ID: {draft_workflow.id}).")

    # 4. Publish workflow
    published_workflow = workflow_service.publish_workflow(
        session=db.session,
        app_model=app_model,
        account=account,
        marked_name="v1.0.0",
        marked_comment="Initial Stage D.1 Visual Chatflow with Evidence Check and Abstention branch."
    )
    app_model.workflow_id = published_workflow.id
    app_model.updated_by = account.id
    app_model.updated_at = naive_utc_now()
    db.session.commit()
    print(f"Workflow published successfully (Published ID: {published_workflow.id}, Version: {published_workflow.version_number}).")
    print(f"App workflow_id linked: {app_model.workflow_id}")

    # 5. Ensure API Token exists
    api_token = db.session.query(ApiToken).filter(
        ApiToken.app_id == app_model.id,
        ApiToken.type == ApiTokenType.APP
    ).first()

    if not api_token:
        generated_key = ApiToken.generate_api_key("app-", 24, session=db.session)
        api_token = ApiToken(
            tenant_id=TENANT_ID,
            app_id=app_model.id,
            type=ApiTokenType.APP,
            token=generated_key
        )
        db.session.add(api_token)
        db.session.commit()
        print(f"Created new API token: {api_token.token[:8]}***")
    else:
        print(f"Existing API token found: {api_token.token[:8]}***")

    # 6. Export DSL
    try:
        dsl_yaml = AppDslService.export_dsl(
            app_model=app_model,
            session=db.session,
            include_secret=False
        )
        os.makedirs('/tmp/workflows', exist_ok=True)
        dsl_export_path = '/tmp/workflows/local_bilingual_rag_chatflow.yml'
        with open(dsl_export_path, 'w', encoding='utf-8') as f:
            f.write(dsl_yaml)
        print(f"Exported Chatflow DSL to {dsl_export_path}")
    except Exception as e:
        print(f"DSL export warning (non-fatal): {e}")

    print(f"\nSUCCESS: Chatflow Application '{APP_NAME}' setup complete.")
    print(f"App ID: {app_model.id}")
    print(f"Studio URL: http://127.0.0.1/app/{app_model.id}/workflow")

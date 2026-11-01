"""
Stage D — Create and Configure Local Bilingual RAG Assistant Application in Dify
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
from models.model import App, AppMode, AppModelConfig, ApiToken
from models.enums import ApiTokenType
from services.app_service import AppService
from services.entities.app_entities import CreateAppParams
from controllers.console.app.model_config_payload import AppModelConfigPayload
from services.app_model_config_service import AppModelConfigService
from events.app_event import app_model_config_was_updated
from libs.datetime_utils import naive_utc_now
from services.app_dsl_service import AppDslService

TENANT_ID = 'b30587b8-f547-461e-bfdf-59e8cb4b1bbb'
ACCOUNT_ID = '5c7a6fd3-2624-4d5a-9256-081444e787c6'
DATASET_ID = '8e29fd5b-9537-46ac-acde-191b457b793e'
APP_NAME = 'Local Bilingual RAG Assistant'

SYSTEM_PROMPT = """أنت مساعد تقني مؤسسي ذكي ثنائي اللغة (العربية والإنجليزية) متخصص في الإجابة على الاستفسارات الفنية بدقة وموثوقية عالية.

القواعد الصارمة الملزمة:
1. الالتزام المطلق بالسياق (Strict Grounding): اعتمد حصراً وبشكل صارم على المعلومات الواردة في الوثائق المرفقة (Context). لا تقدم أي إجابة بناءً على معرفتك الخارجية المسبقة.
2. منع الهلوسة الصارم (Anti-Hallucination): يُحظر تماماً التخمين، أو افتراض حقائق غير موجودة، أو تأليف أي أرقام، تواريخ، مواصفات أو ميزانيات.
3. التوثيق والاقتباس الداخلي الصريح (Inline Citations):
   - عند الإجابة باللغة العربية: اذكر دائماً اسم الوثيقة ورقم الفقرة أو القسم بصيغة: [اسم الوثيقة، رقم الفقرة / القسم].
   - When answering in English: Always cite the source document and section in the format: [Document Name, Section X].
4. الامتناع الصريح في حال عدم التوفر (Explicit Abstention):
   - إذا كان سؤال المستخدم يتعلق بموضوع أو حقائق غير موجودة إطلاقاً في الوثائق المرفقة، يجب عليك الامتناع عن الإجابة فوراً، والرد بالصيغة المحددة التالية بدقة:
     - بالعربية: "المعلومة المطلوبة غير متوفرة في الوثائق المرفقة."
     - بالإنجليزية: "The requested information is not available in the provided documents."
   - لا تحاول أبداً تقديم إجابات عامة أو تخمينية عن الأسئلة غير المدعومة.
5. مطابقة لغة السؤال (Language Consistency): أجب باللغة العربية إذا كان السؤال بالعربية، وأجب بالإنجليزية إذا كان السؤال بالإنجليزية. في الأسئلة العابرة للغات، قدم الإجابة بلغة السؤال مستنداً إلى الوثيقة المرجعية واذكر المصدر بدقة."""

OPENING_STATEMENT = "مرحباً بك! أنا المساعد التقني ثنائي اللغة المبني محلياً. كيف يمكنني مساعدتك اليوم استناداً إلى الوثائق التقنية المعتمدة؟\n\nWelcome! I am your local bilingual technical assistant. How can I assist you today based on verified technical documentation?"

_, flask_app = app.create_app()
with flask_app.app_context():
    account = db.session.get(Account, ACCOUNT_ID)
    tenant = db.session.get(Tenant, TENANT_ID)
    account.set_current_tenant_with_session(tenant, session=db.session)

    # Check if app already exists
    existing_app = db.session.query(App).filter(
        App.tenant_id == TENANT_ID,
        App.name == APP_NAME
    ).first()

    if not existing_app:
        print(f"Creating new app '{APP_NAME}'...")
        params = CreateAppParams(
            name=APP_NAME,
            description="Local bilingual Arabic/English grounded RAG assistant powered by Qwen3.5:4b and BGE-M3 on native Ollama.",
            mode=AppMode.CHAT.value,
            agent_role="",
            icon_type="emoji",
            icon="🤖",
            icon_background="#FFEAD5",
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

    # Prepare model configuration payload
    config_dict = {
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
        "prompt_type": "simple",
        "pre_prompt": SYSTEM_PROMPT,
        "opening_statement": OPENING_STATEMENT,
        "dataset_configs": {
            "retrieval_model": "single",
            "datasets": {
                "strategy": "router",
                "datasets": [
                    {
                        "dataset": {
                            "enabled": True,
                            "id": DATASET_ID
                        }
                    }
                ]
            }
        },
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

    payload = AppModelConfigPayload.model_validate(config_dict)
    validated_config = AppModelConfigService.validate_configuration(
        tenant_id=TENANT_ID,
        config=payload.model_dump(exclude_unset=True),
        app_mode=AppMode.CHAT,
        session=db.session
    )

    new_app_model_config = AppModelConfig(
        app_id=app_model.id,
        created_by=ACCOUNT_ID,
        updated_by=ACCOUNT_ID,
    )
    new_app_model_config = new_app_model_config.from_model_config_dict(validated_config)
    db.session.add(new_app_model_config)
    db.session.flush()

    app_model.app_model_config_id = new_app_model_config.id
    app_model.updated_by = ACCOUNT_ID
    app_model.updated_at = naive_utc_now()

    # Trigger dataset join update
    app_model_config_was_updated.send(
        app_model,
        app_model_config=new_app_model_config,
        session=db.session
    )
    db.session.commit()
    print(f"AppModelConfig configured and committed with ID: {new_app_model_config.id}")

    # Ensure API Token exists
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

    # Export DSL
    try:
        dsl_yaml = AppDslService.export_dsl(
            app_model=app_model,
            session=db.session,
            include_secret=False
        )
        os.makedirs('/tmp/workflows', exist_ok=True)
        with open('/tmp/workflows/local_bilingual_rag_assistant.yml', 'w', encoding='utf-8') as f:
            f.write(dsl_yaml)
        print("Exported DSL to /tmp/workflows/local_bilingual_rag_assistant.yml")
    except Exception as e:
        print(f"DSL export warning (non-fatal): {e}")

    print("SUCCESS: RAG Application setup complete.")

# التقرير الهندسي النهائي: ضمان جودة بصيرة v1.1.0 واستعادة هوية جيب البصرية المتوافقة (QA, Branding Recovery & Closure)

**تاريخ الإغلاق الهندسي:** 10 نوفمبر 2026  
**المستودع والفرع:** `https://github.com/a2sn2/local-rag-dify` (`main`)  
**نطاق التنفيذ:** ترقية وإغلاق ملاحظات **بصيرة — Baseera Docs v1.1.0** + استعادة هوية **محفظة جيب (JAIB)** البصرية المتوافقة مع ترخيص Dify + التحقق الصارم من ثبات الشبكة والبيانات (**Zero Network/Data Mutation**).

---

## الملخص التنفيذي السريع

| المجال | الحالة الفعلية | الدليل والمقياس الموثق |
| :--- | :---: | :--- |
| **أمان بصيرة وتدوير المفتاح** | **PASS (مع تنويه تاريخ Git)** | إبطال مفتاح `app-8l****VrTI` المسرب، إصدار مفتاح جديد محفوظ حصراً في `.secrets/baseera_api_token.env` غير المتتبع (`HTTP 401` للقديم مقابل `HTTP 200` للجديد)، وتنظيف جميع ملفات Baseera المتتبعة. (تظل ملفات ورموز سابقة خاصة بـ `ALHassan AI` في تاريخ Git دون تعديل التزاماً بقيد عدم المساس بها). |
| **التقييم المستقل `v1.1.0` (36 سؤالاً)** | **PASS / VERIFIED (86.11%)** | **`31/36` اجتيازاً صارماً** للتحقق البرمجي (`100% src=True`، **`100% clean=True` دون أي هلوسة أو تسريب**)، بمتوسط زمن استجابة **30.79 ثانية**. بعد التدقيق البشري اليدوي للأسئلة الخمسة المتبقية: 3 أخطاء حقيقية محددة في الاستدلال/الاسترجاع لـ 4B و2 تطابقان تامان معنويًا مع تعبيرات نصية أدق. |
| **رفع المستندات عبر واجهة Publish** | **PASS (مع قيود موثقة)** | استخلاص فعلي عبر `Document Extractor` و`PostgreSQL` في: **Arabic PDF (7.83s)**، **English PDF (8.82s)**، **English DOCX (6.24s)**، و**مقارنة ملفين معاً (15.78s)**. قيود موثقة للملفات الضخمة (`189KB` يتجاوز `4096` توكن — يظهر تحذير صريح دون هلوسة) وأسئلة المتابعة دون إعادة إرفاق الملف. |
| **استعادة هوية JAIB والامتثال للترخيص** | **PASS (100%)** | تشخيص تجاوز `docker-compose.override.yaml` بسبب تمرير `-f` المنفرد، استعادة شعار `JAIB | Dify` المتجهي المزدوج، إبقاء إشعار الحقوق، وإعادة بناء `local-rag/dify-web:1.18.0-jaib`. التحقق البصري عبر 11 لقطة Chrome (`#E4122D`، خطوط، Dark/RTL/Mobile، `0` أخطاء). |
| **ثبات الهوية بعد إعادة التشغيل** | **PASS (100%)** | صمود `local-rag/dify-web:1.18.0-jaib` بالكامل بعد `docker restart dify-web-1` وبعد تشغيل [scripts/start-local-rag.ps1](../../scripts/start-local-rag.ps1) مع صلاحية `Cache-Control`. |
| **الحفاظ على الشبكة و`ALHassan AI` والنسخ** | **PASS (100%)** | مطابقة تامة لقيم `Wi-Fi` و`Mobile Hotspot` و`WSL2` وجدار حماية Ollama (`Local RAG - Ollama Inbound (WSL2 Only)` مفعل `Block`) و`ALHassan AI` (`172` قطعة لم تتغير) وبصمات `SHA-256` لجميع النسخ الخمس في `backups/`. |

---

## 1. نتائج التدقيق الأمني وأدلة تدوير المفتاح

1. **الفحص الشامل لتاريخ المستودع والملفات الحالية (`git rev-list --all` وworking tree):**
   - تم رصد مفتاح Baseera المكشوف في التزام `cf3dabd` (`app-8l****VrTI`) داخل `baseera-docs/FINAL_REPORT.md` و`baseera-docs/USAGE_GUIDE.md` و`baseera-docs/docs/FINAL_ENGINEERING_REPORT.md`.
   - كما رُصدت أسرار تاريخية أخرى سابقة لا تتعلق ببصيرة في التزامات أقدم: رمز `app-I0****PMAi` في التزام `6137f8e` (`docs/FINAL_ENGINEERING_HANDOVER.md`)، ورمز `ALHassan AI` (`app-lT****Lu0P`) في `fddcf18` (`docs/personal-rag/` و`tests/rag-evaluation/run_alhassan_acceptance_suite.py`)، وقيم `WEAVIATE_API_KEY` في `scripts/backup-local-rag.ps1` و`scripts/test-isolated-restore.ps1` (`0d46c2f`).
   - ملف `docker/dify/.env` الفعلي غير متتبع بـ Git (محمي بـ `.gitignore`).

2. **الإجراء التصحيحي المنفذ لـ Baseera Docs:**
   - تم إبطال المفتاح المكشوف مباشرة داخل قاعدة بيانات `dify-api-1` (`api_tokens` — `REVOKED_OLD_TOKENS=1`).
   - تم توليد مفتاح جديد معزول (`60543575-8872-45d3-b92a-86c7e6035683`، الصيغة المموهة `app-Nv****Y3JV`) وحفظه حصراً داخل ملف `.secrets/baseera_api_token.env` المستبعد في `.gitignore`.
   - **الاختبار الحي للتدوير:** أعاد المفتاح القديم **`HTTP 401`** وأعاد المفتاح الجديد **`HTTP 200`**.
   - تم تطهير جميع ملفات بصيرة المتتبعة في المستودع (`FINAL_REPORT.md`، `FINAL_ENGINEERING_REPORT.md`، `USAGE_GUIDE.md`، والمخططات) بحيث خلت تماماً من أي مفاتيح API حية أو مكشوفة، مع إبقاء ملفات `ALHassan AI` التاريخية دون مساس تنفيذاً لقيد الحفاظ الصارم على `ALHassan AI` وبياناته.

---

## 2. تحليل الفجوة: لماذا أظهر التقييم الأول `27/36` مقابل الادعاء السابق `36/36`؟

أظهر التفريغ الجنائي المباشر لسجلات `v1.0.0` الخام (`raw_audit_dump.json` + `evaluation_results.json`):

| جانب الفجوة | التفاصيل المثبتة من السجلات الخام |
| :--- | :--- |
| **التناقض الحسابي** | النتيجة البرمجية الفعلية لـ `v1.0.0` كانت **`27/36 (75.0%)`** مع **9 إخفاقات مسجلة**، إلا أن التقرير القديم سوّق نسبة `36/36 (100%)`. |
| **سوء التجزئة في `v1.0.0` (1,973 شظية)** | استخدمت النسخة القديمة فاصلاً صارماً `"\n\n"` مما مزق الوثائق الثمانية إلى **1,973 قطعة** (منها **1,272** لـ `UK_Model_Services_Contract` وحدها، بينها 372 شظية أصغر من 50 حرفاً مثل `"1.0"` وعناوين منفصلة عن نصوصها). |
| **غياب وسم الوثيقة داخل `{{#context#}}`** | لم يكن نص المقطع يحمل اسم الوثيقة أو تحديد الأطراف، فأدى تداخل عقود مشابهة إلى **تبادل الأطراف** (خلط العميل بالشركة في `DOC-COMP-01` و`PARA-01`)، و**اختلاق أرقام مواد غير موجودة** (`Section 1.3/1.4/1.5` في `FACT-04`)، و**إخفاقات مخفية مررتها الاختبارات السطحية** في `FACT-01` (ذكر `20 بنداً` من العقد البريطاني داخل سؤال سعودي) و`TRAP-05` و`TRAP-06`. |

---

## 3. نتائج التقييم المستقل الحقيقية للإصدار `v1.1.0` (36 سؤالاً × 4 بوابات)

تم إعادة بناء قاعدة المعرفة المعزولة (`0de4f4ec-4c4e-4bc7-bef7-6379466cdfd1`) عبر تقسيم يراعي العناوين والأقسام (`Section-Aware Chunking` بحد `~640` حرفاً لتلافي بتر النصوص أو تجاوز حد `3,072` توكن دخل عند `num_ctx=4096`) مع وسم كل قطعة باسم الوثيقة والأطراف، بإجمالي **743 قطعة مترابطة وموسومة** على محرك البحث الدلالي (`semantic_search`, `top_k=10`, `score_threshold=0.25`) وإلزام النموذج بلغة السؤال الصارمة ومنع الاختلاق.

### أ) النتيجة الإجمالية (بعد التعديل النهائي على [baseera_docs_chatflow.yml](../workflows/baseera_docs_chatflow.yml) المنشور Version 5)

- **النتيجة الآلية الصارمة:** **`31 / 36` (`86.11%`)**
- **بوابة استرجاع المصدر الصحيح (`source_ok`):** **`36 / 36` (`100%`)**
- **بوابة النزاهة ومنع الاختلاق والتسريب (`clean_ok`):** **`36 / 36` (`100%`)** (صفر انتهاكات)
- **متوسط زمن الاستجابة:** **`30.79 ثانية`**
- **ملف النتائج الكامل:** [independent_eval_v2_results.json](../evaluation/independent_eval_v2_results.json)

### ب) التفصيل حسب الفئات الـ 12

| الفئة التقييمية | النتيجة الآلية | النسبة | متوسط الكمون |
| :--- | :---: | :---: | :---: |
| Basic Factual Retrieval (Arabic) | `3/3` | `100%` | `23.40s` |
| Basic Factual Retrieval (English) | `3/3` | `100%` | `29.57s` |
| Semantic Paraphrase (Arabic) | `3/3` | `100%` | `30.26s` |
| Contractual Obligations | `2/3` | `67%` | `29.08s` |
| Missing Terms & Placeholders | `2/3` | `67%` | `26.28s` |
| Clause Comparison | `2/2` | `100%` | `34.64s` |
| Document Comparison | `2/3` | `67%` | `40.39s` |
| Summarization | `2/2` | `100%` | `37.20s` |
| Risk Analysis | `3/3` | `100%` | `35.41s` |
| Incomplete Evidence | `2/2` | `100%` | `28.37s` |
| Reasonable Interpretation | `1/3` | `33%` | `29.73s` |
| Hallucination Trap | **`6/6`** | **`100%`** | `29.28s` |

### ج) التدقيق النوعي الصريح للحالات الخمس المتبقية

1. **`MISS-01` (تطابق معنوي 100% / صرامة regex الاختبار):** أجاب النظام بدقة متناهية أن نسبة الدفعة الأولى في البند 19 متروكة كخانة فارغة `[.....]%` ورفض التخمين. أشار سكريبت الفحص لعدم ورود عبارة `"توقيع العقد"` رغم أن السؤال لم يسأل عن توقيت الدفع بل عن النسبة فقط.
2. **`OBLIG-01` (مرادف لغوي جزئي):** استخلص النظام التزامات الشركة بدقة (`ضمان جودة الكود حسب المواصفات المعتمدة، اتباع الممارسات الأمنية، الربط البرمجي...`) مستخدماً مصطلح `"التطوير"` و`"البرمجي"` بدلاً من الحرفي `"البرمجة"`/`"التصميم"`.
3. **`DOC-COMP-01` (مقارنة مركبة من 3 أجزاء عبر نسختين متشابهتين):** أجاب النظام عن مدة المراجعة (`15 يوم عمل` في النهائية مقابل `5 أيام` في `v1.0.0`) وعن الإنهاء بأمانة دون هلوسة، لكن مقارنة 3 محاور في استعلام واحد ملأت مقاعد `top_k=10` ببنود المراجعة والإنهاء ولم يصل مقطع البند السادس (`سداد كامل المستحقات` — الملكية الفكرية) ضمن العشر قطع، فصرح النظام بأمانة بأن المقطع لم يظهر في السياق المسترجع.
4. **`INTERP-01` (تناقض منطقي موضعي للنموذج `qwen3.5:4b` عند `think=False`):** افتتح النموذج السطر الأول بعبارة خاطئة (`"لا، لا يشمل الدعم..."`) ثم ناقض نفسه مباشرة في الأسطر التالية بالتحليل الصحيح (`"بما أن الخلل حدث بعد 45 يوماً، فهو يقع ضمن فترة الـ 365 يوماً وبالتالي يشمل الدعم المجاني"`). خلل منطقي حقيقي من حجم 4B مسجل بأمانة.
5. **`INTERP-02` (عكس نسختي العقد في بند 19.6 عند التداخل):** رغم وجود الوسم التوثيقي `[الوثيقة: ...]`، عكس النموذج قاعدة `"استرداد المبالغ الزائدة"` (الموجودة في النسخة النهائية) ونسبها لـ `v1.0.0` بسبب التشابه الحرفي الشديد بين النسختين المتجاورتين في السياق.

---

## 4. نتائج تدقيق Source Manifest وتراخيص المصادر

تم تحديث [source_manifest.json](../manifest/source_manifest.json) و[SOURCE_MANIFEST.md](../SOURCE_MANIFEST.md) بتصنيف دقيق إلى 4 فئات:

| التصنيف الحقيقي | الملفات والوضع في KB | التحقق القانوني والترخيصي |
| :--- | :--- | :--- |
| **`official_government`** | `UK_Model_Services_Contract_Core_Terms_v2.2A` (`.docx` مرجعي + `.md` مفهرس بـ **440 قطعة**) | صادر رسمياً عن Cabinet Office / Crown Commercial Service تحت ترخيص **OGL v3.0**. |
| **`open_source_standard`** | عقود Bonterms الثلاثة (`Cloud Terms v1.0`: **75 قطعة**، `Mutual NDA v1.0`: **19 قطعة**، `PSA v1.2`: **96 قطعة**) مع نسخ `.pdf` الأصلية | نماذج تجارية قياسية مفتوحة المصدر بترخيص صريح **CC BY 4.0**. |
| **`community_open_template`** | النماذج العربية الأربعة من مستودع `mustafaeida/devLegal-arabic-framework` (`51 + 40 + 10 + 12 = 113 قطعة`) | **تنويه تصحيحي حاسم:** ليست وثائق حكومية سعودية رسمية (بسبب تعذر الوصول لمواقع `.gov.sa`)؛ مستودع GitHub يعيد **HTTP 404** على مسار `/license`؛ ونص العقد يعتمد **المحكمة التجارية بالرياض** في البند الثامن بينما ذُكر نظام المعاملات المدنية في README المستودع فقط. |
| **`experimental_test_fixture`** | 3 ملفات اختبارية في [evaluation/fixtures/](../evaluation/fixtures/): `Experimental_Test_Contract_Upload.pdf` (`1,592 B`)، `Experimental_Test_Service_Agreement_Upload.docx` (`37,393 B`)، و`Experimental_Test_Arabic_Contract_Upload.pdf` (`90,975 B`) | مصممة محلياً غير مفهرسة في KB، لإثبات مسار `Document Extractor` بعيداً عن محتوى قاعدة المعرفة. |

---

## 5. نتائج اختبارات رفع المستندات عبر واجهة Publish (Live End-to-End + Postgres Trace)

تم التحقق عبر مسار WebApp الفعلي (`/api/passport` + `/api/parameters` + `/api/files/upload` + `/api/chat-messages`) لتطبيق النشر الحقيقي **`http://127.0.0.1/chat/JWUhTnPUst1llzGJ`**، كما تم فحص جدول `workflow_node_executions` في PostgreSQL لإثبات عبور البيانات عبر العقد التالية فعلياً:
`start -> file_check (true) -> document_extractor -> llm_uploaded -> answer_uploaded` (مع `retriever_resources_count = 0`).

| الاختبار | الملف المرفوع | الزمن | السلوك والنتيجة الفعلية |
| :--- | :--- | :---: | :--- |
| **`UPLOAD-AR-PDF-01`** | `Experimental_Test_Arabic_Contract_Upload.pdf` (عربي RTL) | `7.83s` | **PASS:** استخرج الأطراف (شركة النخبة ومؤسسة الحلول الرقمية)، المدة `6 أشهر`، القيمة `240,000 ريال` والدفعة الأولى `96,000 ريال (40%)`، غرامة `1,500 ريال/أسبوع بحد 12% (28,800)`، وصرح بأن رقم التسجيل الضريبي `[خانة فارغة]` دون اختلاق. |
| **`UPLOAD-EN-PDF-02`** | `Bonterms_Mutual_NDA_v1.0.pdf` | `8.82s` | **PASS:** استخرج معيار العناية في Section 3، و`injunction / equitable relief` في Section 11، وأجاب بالإنجليزية أن القانون الحاكم غير محدد في متن العقد بل في صفحة الغلاف. |
| **`UPLOAD-DOCX-03`** | `Experimental_Test_Service_Agreement_Upload.docx` | `6.24s` | **PASS:** قرأ النص والجداول (`80,000 SAR` + `240,000 SAR = 320,000 SAR`، غرامة يومية بحد `8%`) وصرح أن `Bank IBAN` غير موجود بالملف. |
| **`UPLOAD-MULTI-04`** | `Arabic PDF` + `English DOCX` **معاً في رسالة واحدة** | `15.78s` | **PASS:** قارن كلا الملفين في جدول منظم (القيمة المالية، الدفعات، مدة الفحص 10 أيام، الإنهاء 30 يوماً وتصفية 5% مقابل ضمان وغرامة يومية). |
| **`UPLOAD-LARGE-05`** | `UK_Model_Services_Contract_Core_Terms_v2.2A.docx` (`189,546` حرفاً) | `7.54s` | **PARTIAL / SAFE GUARD:** استخرج `document_extractor` كامل `189,546` حرفاً وأرسلها إلى `llm_uploaded` (`in_len=189,801`)، وبسبب نافذة سياق Ollama الافتراضية (`4096 tokens`) تم إسقاط النص، فأظهر النظام التحذير الصريح **`⚠️ CRITICAL WARNING: Document Size Exceeds Context Limit (~4096 tokens)`** ورفض اختلاق البنود 1 أو 31. |
| **`UPLOAD-FOLLOWUP-06`** | متابعة شفهية في الدور الثاني **دون إعادة إرفاق الملف** | `6.43s` | **ARCHITECTURAL CAVEAT:** لأن متغير Dify `sys.files` يُفرّغ لكل رسالة مفردة، وجّه `file_check` الدور الثاني نحو `ELSE -> knowledge_retrieval`، فاستدعى 10 مقاطع من العقد السحابي بالقاعدة بدلاً من الذاكرة فقط. تم توثيق التوصية في [USAGE_GUIDE.md](../USAGE_GUIDE.md) بإبقاء الملف مرفقاً أثناء المتابعات. |

---

## 6. تشخيص سبب اختفاء هوية محفظة جيب (JAIB) وعودة شعار Dify الأصلي

أثبت الفحص المعمّق عبر `docker inspect dify-web-1` وتحليل نصوص التشغيل ما يلي:

1. **السبب المباشر للاختفاء:** في 9 نوفمبر `23:22` أُعيد إنشاء حاوية `dify-web-1` بصورة المنبع **`langgenius/dify-web:1.18.0`** رغم وجود الصورة المعدلة محلياً `local-rag/dify-web:1.18.0-jaib` (`2026-11-08`).
2. **السبب الهندسي الجذري (Docker Compose Override Bypass):** تستخدم نصوص التشغيل ([scripts/start-local-rag.ps1](../../scripts/start-local-rag.ps1)، و`stop-local-rag.ps1`، و`restore-local-rag.ps1`) المعامل الصريح `-f "docker\dify\docker-compose.yaml"`. في محرك **Docker Compose v2**، يؤدي تحديد `-f` يدوياً إلى **تعطيل القراءة التلقائية لملف `docker-compose.override.yaml`** ما لم يُمرر بدوره صراحةً، وبالتالي تجاهل النظام تعيين `web.image: local-rag/dify-web:1.18.0-jaib` وعاد فوراً لشعار وألوان Dify الأصلية (`#0033FF` وغياب `/themes/jaib/jaib-theme.css` -> `HTTP 404`).
3. **السبب الثانوي المتعلق بملفات الشعار:** تبيّن أن الالتزامين `5be24e5` و`84afb91` قاما سابقاً بإزالة شعار Dify من `logo.svg` و`logo-dark.svg` تحت مسمى "White-Label".

---

## 7. مراجعة الترخيص (Dify Open Source License) وتصميم التعايش النظامي

- **المرجع الترخيصي:** يتضمن ترخيص Dify Open Source (المعدل عن Apache 2.0) شرطاً صريحاً يحظر عند استخدام واجهة الويب الأمامية (`web/` / حاوية `dify-web`) **إزالة أو تعديل شعار Dify أو إشعارات حقوق النشر** بدون ترخيص تجاري مدفوع من LangGenius.
- **المعالجة النظامية النظيفة (License-Compliant Co-Branding):**
  - تم تصميم [logo.svg](../../themes/jaib/assets/logo.svg) و[logo-dark.svg](../../themes/jaib/assets/logo-dark.svg) بأبعاد `152x36` كمتجهات SVG نقية (**Pure Vector — صفر صور PNG مضمنة**) تضم: **علامة جيب المتجهية (`جيب / JAIB` بأحمر `#E4122D`) + خط فاصل متزن + الشعار المتجهي الرسمي غير المعدل لـ Dify (`#0033FF` أزرق في النهاري و`#3072FF / #F4F4F5` في الليلي)**.
  - الحفاظ التام على سطر الحقوق `© 2026 LangGenius, Inc. All rights reserved.` في شاشة تسجيل الدخول وعلى تذييل **`مشغل بواسطة JAIB | Dify`** في واجهة بصيرة المنشورة، مع فصل هويات المنظومات الثلاث بوضوح (Dify كمحرك، محفظة جيب كهوية مؤسسية مخصصة، وبصيرة كمنتج ذكاء مستندي مستقل).

---

## 8. تفاصيل استعادة الهوية البصرية وإصلاح ديمومة التشغيل

1. **إعادة صياغة شعارات Co-branding SVG (`152x36`)** في `themes/jaib/assets/logo.svg` و`logo-dark.svg`.
2. **تحسين [jaib-theme.css](../../themes/jaib/css/jaib-theme.css):** ضبط تناسب الشعار الصغير في تذييل المحادثة المنشورة (`img[src*="/logo/logo"].h-4` بارتفاع `18px` متناسق ومنع انضغاطه داخل `w-9`)، وضمان تبديل كل صور `/logo/logo.svg` إلى `/logo/logo-dark.svg` في الوضع الداكن مع إبطال فلتر `invert` الخاص بـ Tailwind (`filter: none !important;`) حتى لا يتغير الأحمر القرمزي `#E4122D` إلى لون سماوي.
3. **حقن التنسيقات المستقر وقت البناء (`Dockerfile.jaib-web`):** بناء الصورة `local-rag/dify-web:1.18.0-jaib` عبر إلحاق `jaib-theme.css` بجميع ملفات CSS الثابتة في `.next/static/chunks/*.css` دون أي اعتراض Stream وقت التشغيل.
4. **إصلاح نصوص الإدارة الدائمة:** تعديل [scripts/start-local-rag.ps1](../../scripts/start-local-rag.ps1) و[scripts/stop-local-rag.ps1](../../scripts/stop-local-rag.ps1) و[scripts/restore-local-rag.ps1](../../scripts/restore-local-rag.ps1) لبناء قائمة `-f` ديناميكياً تضم `docker-compose.override.yaml` متى وُجدت، مع عرض صورة `dify-web-1` الفعالة في مخرجات التشغيل للتحقق الفوري.

---

## 9. التوثيق البصري قبل وبعد الاستعادة وفحص Chrome CDP

تم أخذ 6 لقطات **قبل الاستعادة (`before/`)** من الحاوية المرجعية المنهارة `langgenius/dify-web:1.18.0` و11 لقطة **بعد الاستعادة (`after/`)** عبر متصفح Chrome حقيقي (Headless CDP مع جلسة مصادقة حقيقية لـ Studio/Datasets/Workflow)، مع فحص الخصائص المحسوبة داخل الـ DOM:

| الشاشة والوضع | قبل الاستعادة (`before/`) | بعد الاستعادة (`after/`) | التحقق الآلي للـ DOM / Console |
| :--- | :--- | :--- | :--- |
| **تسجيل الدخول (`signin`)** | أزرق `rgb(0, 51, 255)`، شعار `48x22`، `jaibCss=404` | أحمر جيب `rgb(228, 18, 45)`، شعار `152x36` متجهي مزدوج، حقوق محفوظة، `jaibCss=200` | [01_signin.png](../../docs/evidence/recovery/after/01_signin.png) — `favicon=200` |
| **لوحة التطبيقات / Home & Studio (`/apps` و `/`)** | أزرق `rgb(0, 51, 255)`، خطوط افتراضية | `rgb(228, 18, 45)`، خطوط عربية متسقة، تبويب نشط قرمزي شفاف | [02_dashboard_apps.png](../../docs/evidence/recovery/after/02_dashboard_apps.png) — **`0/0/0` أخطاء** |
| **قاعدة المعرفة (`datasets`)** | أزرق Dify | زر إنشاء `#E4122D`، شعار `152x36` | [04_datasets.png](../../docs/evidence/recovery/after/04_datasets.png) — **`0/0/0` أخطاء** |
| **مخطط بصيرة (`workflow`)** | زر Publish أزرق | زر Publish `#E4122D`، **بقاء `.react-flow` بوضع `direction: ltr`** | [05_baseera_workflow.png](../../docs/evidence/recovery/after/05_baseera_workflow.png) |
| **واجهة بصيرة المنشورة (`/chat/JWUhTnPUst1llzGJ`)** | إرسال أزرق `rgb(28, 100, 242)` | إرسال `#E4122D`، تذييل `مشغل بواسطة جيب JAIB \| Dify` | [06_baseera_published_chat.png](../../docs/evidence/recovery/after/06_baseera_published_chat.png) |
| **الوضع الليلي (`Dark Mode` للوحة والمحادثة)** | غير مدعوم بتغييرات جيب | خلفية فحمية داكنة `rgb(18, 19, 22)`، استبدال `logo-dark.svg` نظيف دون انعكاس لوني | [07_apps_dark.png](../../docs/evidence/recovery/after/07_apps_dark.png)، [10_baseera_chat_dark.png](../../docs/evidence/recovery/after/10_baseera_chat_dark.png) — **`0/0/0` أخطاء** |
| **العربية RTL (`ar-EG`) والجوال (`390x844`)** | — | اتجاه `dir="rtl"` سليم، تجاوب شريط المحمول دون اقتطاع الشعار (`106x25`) | [08_apps_arabic_rtl.png](../../docs/evidence/recovery/after/08_apps_arabic_rtl.png)، [09_apps_mobile_390.png](../../docs/evidence/recovery/after/09_apps_mobile_390.png)، [11_baseera_chat_mobile_390.png](../../docs/evidence/recovery/after/11_baseera_chat_mobile_390.png) — **`0/0/0` أخطاء** |

السجل المعملي التفصيلي محفوظ في [before/audit.json](../../docs/evidence/recovery/before/audit.json) و[after/audit.json](../../docs/evidence/recovery/after/audit.json).

---

## 10. نتائج اختبارات الثبات وإعادة التشغيل

1. **`docker restart dify-web-1`:** صمدت الحاوية تماماً على صورة `local-rag/dify-web:1.18.0-jaib`، وأرجعت الطلبات `/themes/jaib/jaib-theme.css` (`HTTP 200`) و`/logo/logo.svg` (`dify-brand` + `jaib-brand` مضمّنان، `Cache-Control: public, max-age=0`).
2. **تنفيذ [scripts/start-local-rag.ps1](../../scripts/start-local-rag.ps1):** حافظ السكريبت بعد التعديل على كامل الحاويات دون تراجع لـ `dify-web-1` (`Container dify-web-1 Running` — **`Web Image: local-rag/dify-web:1.18.0-jaib`**).

---

## 11. التحقق من الحفاظ الكامل على الشبكة والبيانات (Task C Lock)

- **واجهات وعناوين الشبكة (لم يمسها أي تغيير):**
  - `Wi-Fi`: `192.168.100.27`
  - `Local Area Connection* 2` (Mobile Hotspot): `192.168.137.1`
  - `vEthernet (WSL)`: `172.19.160.1/20`
  - قاعدة جدار الحماية: `Local RAG - Ollama Inbound (WSL2 Only)` (`Enabled=True`, `Action=Allow`, `EdgeTraversalPolicy=Block`) — مطابقة 100% لخط الأساس.
  - ارتباط حاوية Plugin Daemon منفذ `5003`: محصور على `127.0.0.1:5003`.
- **تطبيق وبيانات `ALHassan AI`:** المعرف `a517d042-df7a-4fc0-a1ac-70ffb44236c5` وقاعدة المعرفة `c58ff9a4-0017-4ebf-9aec-e1d8ff48744f` (**172 قطعة، آخر تعديل `2026-11-09 18:39:22`**) سليمة ولم يُجرَ عليها أي تعديل.
- **النسخ الاحتياطية المشفرة (`backups/*.enc`):** تطابق كامل ببصمات SHA-256 قبل التعديل وبعده للنسخ الخمس (`backup_20261101_200610.enc` حتى `backup_20261108_193225.enc`).

---

## 12. القيود المعروفة والتحفظات الصريحة (Honest Limitations)

1. **توقّف عقدة تنفيذ الأكواد (`dify-sandbox-1`):** تعيد حاوية Sandbox رمز `HTTP 401` بسبب عدم تطابق تهيئة مفتاح `.env` الموروثة؛ لذا جرى تجنب استخدام عقد `Code` أو `Template Transform` في مخطط بصيرة حفاظاً على استقرار المخطط ودون تعديل إعدادات البيئة المشتركة.
2. **حد السياق الأحادي للنموذج `qwen3.5:4b` (`4096` tokens على 6GB VRAM):** لا يمكن معالجة ملفات تتجاوز ~12,000 حرف دفعة واحدة عند إرفاقها مباشرة، ويعرض النظام تحذيراً واضحاً (`UPLOAD-LARGE-05`) بدلاً من الاختلاق. المعالجة المثلى للملفات الكبيرة (180KB+) هي فهرستها داخل KB.
3. **أسئلة المتابعة دون إعادة إرفاق الملف (`UPLOAD-FOLLOWUP-06`):** إفراغ متغير `sys.files` تلقائياً في Dify مع كل رسالة يوجه أي رسالة لاحقة خالية من مرفق إلى البحث في قاعدة المعرفة؛ لذا ينبغي إبقاء الملف مرفقاً أثناء المتابعة.
4. **بعض حالات الفشل الفردي لنموذج 4B ومهام المقارنة الثلاثية (`31/36` آلي):** حُصرت بدقة في التناقض الموضعي `INTERP-01`، وقلب بند `19.6` في `INTERP-02`، وإشباع `top_k=10` في `DOC-COMP-01`.
5. **الأسرار السابقة في تاريخ Git الخاص بـ `ALHassan AI` و`backup-local-rag.ps1`:** تبقى في تاريخ الالتزامات السابقة دون المساس بها التزاماً بقيد عدم تعديل منظومة `ALHassan AI`؛ يُوصى في دورة صيانة مستقلة مخصصة لـ `ALHassan AI` بتدوير رمزه وإعادة كتابة تاريخ Git بأداة `git-filter-repo` إن لزم.

---

## 13. المعمارية النهائية والروابط التشغيلية الحية

- **رابط منصة Dify / JAIB الرئيسية:** [http://127.0.0.1](http://127.0.0.1)
- **تطبيق بصيرة المنشور (`Publish Chatflow v1.1.0 | Version 5`):** [http://127.0.0.1/chat/JWUhTnPUst1llzGJ](http://127.0.0.1/chat/JWUhTnPUst1llzGJ) (`App ID: 1b555bfe-8c5d-401b-bdd6-3a7862f467ff`)
- **قاعدة المعرفة المعزولة:** `Baseera Docs — Evaluation Knowledge` (`Dataset ID: 0de4f4ec-4c4e-4bc7-bef7-6379466cdfd1`، **743 قطعة** عبر 8 وثائق)
- **ملف التصدير المنظف (Sanitized DSL):** [baseera_docs_chatflow.yml](../workflows/baseera_docs_chatflow.yml)

---

## 14. تغييرات Git الموثقة وبصمة الإغلاق

- **الالتزام الهندسي الأساسي (جميع الإصلاحات والأصول ولقطات القبول والاختبارات):** `6013b870b1b05a0a882486cbb902a0205212e42e` (`6013b87`) على فرع `main` (39 ملفاً).
- **الالتزام النهائي:** إضافة هذا التقرير الشامل [FINAL_QA_AND_BRANDING_REPORT.md](./FINAL_QA_AND_BRANDING_REPORT.md) (تُسجل بصمته النهائية بعد الدفع مباشرةً في مخرجات الإغلاق).

---

## 15. التوصية النهائية للاعتماد (Go / No-Go Recommendation)

**التوصية: GO (معتمد للتشغيل المحلي والاستخدام الإنتاجي التجريبي الموجه وفق الضوابط المذكورة).**  
أثبتت منظومة **بصيرة v1.1.0** ثباتاً كاملاً في استرجاع المصادر (`100%`)، وخلوّاً تاماً من اختلاق المراجع والهلوسة في الاختبارات الآلية (`100% clean`)، وتفعيلاً حقيقياً ومثبتاً لرفع وتحليل `PDF` العربي والإنجليزي و`DOCX`، بالتكامل مع استعادة كاملة ودائمة لهوية **JAIB | Dify** المتوافقة ترخيصياً وبصرياً دون أي مساس بالشبكة أو بيانات `ALHassan AI`.

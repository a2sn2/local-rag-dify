# تقرير التدقيق المعماري والتهيئة الفعلية لمنظومة ALHassan AI
# Phase A: Deployed Configuration & Baseline Architectural Audit Report

- **اسم النظام:** ALHassan AI — Personal Knowledge Assistant
- **التاريخ:** 9 نوفمبر 2026
- **المنصة:** Dify Enterprise Community Edition v1.18.0
- **النماذج المحلية:** `qwen3.5:4b` (LLM) و `bge-m3:latest` (Embedding)
- **قاعدة البيانات المتجهية:** Weaviate v1.39.13 (High-Quality Hybrid Search)

---

## 1. التدقيق المقارن: الموثق في الوثائق مقابل المنشور الفعلي (Documented vs. Deployed)

تم إجراء فحص برمجي مباشر عبر قواعد بيانات PostgreSQL ومحرك Dify الداخلي ومقارنتها بما هو معلن في ملفات التوثيق السابقة ومخطط الـ DSL (`workflows/alhassan_ai_chatflow.yml`):

| المكون / الإعداد | القيمة في التوثيق السابق | القيمة في مخطط DSL | القيمة الفعلية في قاعدة البيانات والنظام الحي | المطابقة | الملاحظات الهندسية |
|---|---|---|---|---|---|
| **معرف التطبيق (App ID)** | `a517d042...` | `a517d042...` | `a517d042-df7a-4fc0-a1ac-70ffb44236c5` | **متطابق** | نمط `advanced-chat` |
| **معرف سير العمل (Workflow ID)** | `760383a9...` | - | `760383a9-f94a-42f1-b3ac-cfa920b39e39` (v1) | **متطابق** | سير عمل منشور ونشط |
| **معرف قاعدة المعرفة (Dataset ID)** | `c58ff9a4...` | `c58ff9a4...` | `c58ff9a4-0017-4ebf-9aec-e1d8ff48744f` | **متطابق** | نمط `high_quality` |
| **نمط الاسترجاع في العقدة (Retrieval Mode)** | `single` | `single` | `single` | **متطابق** | **نقطة ضعف معمارية حرجة (انظر القسم 2)** |
| **قيمة Top-K في العقدة** | 5 | 5 (في multiple_config) | **مهملة كلياً في العقدة** | **تعارض دلالي** | يتم أخذها من إعدادات قاعدة البيانات وليس من العقدة |
| **قيمة Top-K في قاعدة المعرفة** | 5 | - | `datasets.retrieval_model.top_k = 5` | **متطابق** | هي المصدر الفعلي الوحيد لقيمة Top-K |
| **طريقة البحث (Search Method)** | Hybrid Search | - | `hybrid_search` (Weaviate Vector + BM25) | **متطابق** | مفعلة ومؤكدة برمجياً |
| **عتبة المطابقة (Score Threshold)** | غير محددة | `null` | `score_threshold_enabled = false` | **متطابق** | **نقطة ضعف حرجة: تمرير كافة النتائج دون فلترة** |
| **إعادة الترتيب (Reranking)** | معطلة | `reranking_enable: false` | `reranking_enable = false` | **متطابق** | معطلة لتوفير الذاكرة وسرعة المعالجة |
| **عدد المقاطع (Segments Count)** | 172 | - | **172 مقطعاً** | **متطابق** | 32 مقطعاً منها ذات جودة منخفضة (< 50 محرفاً) |
| **استراتيجية التقطيع (Chunking)** | 600 tokens / 60 overlap | - | `separator="\n\n", max_tokens=600, overlap=60` | **متطابق** | فصل العناوين عن محتواها (انظر القسم 3) |

---

## 2. الكشف المعماري الحرج: لغز نمط الاسترجاع `single` مقابل `multiple`

من خلال فحص الكود المصدري لمحرك Dify v1.18.0 داخل الحاوية `dify-api-1` وتحديداً الملفات:
- `/app/api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py`
- `/app/api/core/rag/retrieval/dataset_retrieval.py`

تم اكتشاف سلوك برمجي بالغ الأهمية يفسر بطء الاستجابة ومصدر الإعدادات:

### أولاً: أين تذهب معلمات `multiple_retrieval_config` في نمط `single`؟
في `knowledge_retrieval_node.py` (الأسطر 210-233):
```python
if str(node_data.retrieval_mode) == DatasetRetrieveConfigEntity.RetrieveStrategy.SINGLE and query:
    model = node_data.single_retrieval_config.model
    retrieval_resource_list = self._rag_retrieval.knowledge_retrieval(
        request=KnowledgeRetrievalRequest(
            dataset_ids=dataset_ids,
            retrieval_mode="single",
            model_name=model.name,
            # لاحظ: لا يتم تمرير top_k أو score_threshold هنا إطلاقاً!
        )
    )
```
**النتيجة المؤكدة:** عندما يكون نمط العقدة `retrieval_mode: single`، فإن معلمات `top_k: 5` و `score_threshold` الموجودة في العقدة أو ملف الـ DSL تُهمل تماماً ولا تصل إلى دالة الاسترجاع.

### ثانياً: من أين يحصل النظام على Top-K وطريقة البحث في نمط `single`؟
في `dataset_retrieval.py` -> دالة `single_retrieve` (الأسطر 736-760):
```python
retrieval_model_config = selected_dataset.retrieval_model if selected_dataset.retrieval_model else default_retrieval_model
top_k = retrieval_model_config["top_k"]
retrieval_method = retrieval_model_config["search_method"]
score_threshold = retrieval_model_config.get("score_threshold", 0.0) if retrieval_model_config.get("score_threshold_enabled") else 0.0
```
**النتيجة المؤكدة:** مصدر التهيئة الفعال الفعلي في النظام الحالي هو سجل جدول `datasets` في PostgreSQL (`retrieval_model`) وليس عقدة مسار العمل!

### ثالثاً: الكلفة الخفية لنمط `single` — استدعاء LLM إضافي غير مبرر (Router Overhead)
في `dataset_retrieval.py` (الأسطر 665-694):
- صُمم نمط `single` لتوجيه الاستعلام نحو قاعدة معرفة واحدة من بين عدة قواعد عبر وكيل (ReAct / Function Calling Router).
- على الرغم من أن تطبيقنا لا يحتوي سوى على **قاعدة معرفة واحدة فقط** (`ALHassan Personal Knowledge Base`)، إلا أن محرك Dify في نمط `single` كان يستدعي نموذج `qwen3.5:4b` أولاً ليقرر أي قاعدة يختار!
- **الكلفة الزمنية:** هذا الاستدعاء التوجيهي غير الضروري كان يستهلك بين **12 إلى 18 ثانية إضافية** قبل أن تبدأ عملية البحث الفعلي، مما ضاعف زمن الاستجابة الكلي (حوالي 28 ثانية بدلاً من 8 ثوانٍ)!

---

## 3. التدقيق الجذري لجودة التقطيع (Chunking Quality Deficiencies)

تم فحص المقاطع الـ 172 الفعلية المسجلة في جدول `document_segments`:
1. **عزل العناوين (Orphan Headings):**
   - استخدام `\n\n` كفاصل صارم في `FixedRecursiveCharacterTextSplitter` أدى إلى فصل العناوين الرئيسية والفرعية عن فقراتها، مثل:
     - مقطع 6 (22 رمزاً): `'0. الهدف وطريقة الاستعمال'`
     - مقطع 10 (23 رمزاً): `'1. الهوية والبيانات الأساسية'`
     - مقطع 14 (34 رمزاً): `'1.1 تعريف مختصر جاهز لإجابة RAG'`
2. **المقاطع الفارغة وشبه المعدومة (Low-Information Chunks):**
   - وُجد **32 مقطعاً** يقل طول كل منها عن 50 محرفاً (تمثل 18.6% من إجمالي المقاطع المفهرسة).
   - أسوأ الأمثلة: مقطع 9 بطول 3 محارف فقط ويحتوي الفاصل الأفقي `'---'`، ومقاطع تحتوي عناوين فقط دون أي معلومات داعمة.
3. **تشتيت السياق (Context Fragmentation):**
   - في بعض الجداول (مثل جدول بيانات الهوية وقنوات التواصل)، تم تقطيع بعض الصفوف بعيداً عن رأس الجدول، مما يحرم نموذج التضمين من معرفة الحقل المقابل للقيمة.

---

## 4. تدقيق عقدة التحقق من الأدلة (Evidence Check Node Flaw)

- **المنطق الحالي في الـ DAG:**
  `retrieval.result is not empty`
- **الخلل الفعلي المرصود:**
  - نظراً لأن `score_threshold_enabled = false`، فإن محرك المتجهات Weaviate يُعيد دائماً وأبداً أعلى 5 مقاطع (Top-5 Nearest Neighbors) لأي استعلام يُطرح عليه، حتى لو كان استعلاماً وهمياً أو مضللاً أو خارج النطاق كلياً (مثل: "مشروع مطار دبي" الذي أعاد 6 مقاطع بدرجات تشابه منخفضة 0.44 - 0.47).
  - نتيجة لذلك: لم تكن نتيجة `retrieval.result` فارغة قط!
  - **المسار الشرطي للامتناع (`false` branch -> `answer_abstain`) لم يُفعّل مطلقاً في أي استعلام حي!**
  - النظام كان يعتمد بنسبة 100% على حث النموذج اللغوي (Prompting) للامتناع، وهو ما يشكل خطراً كبيراً لارتكاب هلوسة في حال صاغ المستخدم السؤال بأسلوب احتيالي.

---

## 5. مصفوفة التوصيات المعمارية للتصحيح

1. **التحول إلى نمط `retrieval_mode: multiple` (أو التوجيه المباشر):**
   - إلغاء استدعاء الـ LLM Router لتسريع الاستجابة بنسبة تزيد عن 50% وتخفيض الكمون من ~28 ثانية إلى أقل من 10-12 ثانية.
   - تمكين عقدة التدفق من التحكم المباشر والدقيق في `top_k` و `score_threshold`.
2. **تطبيق عتبة مطابقة حتمية (Deterministic Score Threshold):**
   - قياس التوزيع الفعلي لدرجات التشابه وضبط عتبة هجينة (بين 0.50 و 0.52) لتصفية المقاطع غير ذات الصلة آلياً قبل وصولها للنموذج.
   - تفعيل مسار الامتناع الصريح في الـ DAG حتمياً عند فشل الاسترجاع دون استهلاك موارد الـ GPU.
3. **تحسين تقطيع المعرفة (Semantic Chunking Optimization):**
   - التخلص من المقاطع المعزولة (32 مقطعاً) والحفاظ على ترابط العناوين مع محتواها.


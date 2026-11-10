# بيان وتصنيف مصادر الوثائق — مشروع «بصيرة — Baseera Docs» (Source Manifest)

**المشروع:** بصيرة — Baseera Docs  
**تاريخ التحديث والتدقيق:** 10 نوفمبر 2026  
**المسار المحلي:** `C:\Users\alhassanalshami\local-rag\baseera-docs\`

---

## منهجية التصنيف وحالة الفهرسة (Verification & Transparency Standard)

لضمان الدقة القانونية والهندسية التامة، تم تقسيم جميع ملفات المشروع إلى **3 تصنيفات صريحة وواضحة** مع بيان حالة كل ملف في قاعدة المعرفة (`Weaviate KB`):

1. **وثائق حكومية رسمية (`Official Government Documents`):** صادرة رسمياً عن جهة حكومية ومحمية بترخيص حكومي مفتوح.
2. **نماذج قياسية مفتوحة المصدر (`Open-Source Standard Legal Templates`):** نماذج تعاقدية مراجعة من جهات متخصصة بترخيص `CC BY 4.0` صريح.
3. **نماذج مجتمعية استرشادية ومستندات تجريبية (`Community Advisory Templates & Experimental Test Fixtures`):** قوالب مفتوحة مجتمعية أو مستندات تجريبية مصممة لاختبارات الرفع والمقارنة في بيئة الـ QA.

> **تنويه تصحيحي مهم حول المصادر السعودية:**  
> تعذّر الوصول الشبكي أثناء مرحلة الاستحواذ إلى مواقع الجهات الحكومية السعودية (`.gov.sa` مثل `kku.edu.sa` و`ncnp.gov.sa` و`dga.gov.sa`) بسبب حجب Cloudflare وانتهاء المهلة الشبكية. بناءً عليه، **لا تتضمن قاعدة المعرفة الحالية أي وثيقة صادرة رسمياً عن جهة حكومية سعودية**. الوثائق العربية الأربع الموجودة هي **نماذج مجتمعية استرشادية (Community GitHub Templates)** من مستودع `devLegal-arabic-framework` وليست مستندات حكومية رسمية.

---

## 1. الوثائق الحكومية الرسمية (Official Government Documents)

| اسم الملف | الصيغة | الحجم | مفهرس في KB؟ | المصدر والترخيص الموثق | بصمة SHA-256 |
| :--- | :---: | :---: | :---: | :--- | :--- |
| `UK_Model_Services_Contract_Core_Terms_v2.2A.docx` | DOCX | 177,274 B | لا (أصل مرجعي وDOCX) | **UK Cabinet Office / Crown Commercial Service (2025)**<br>Open Government Licence v3.0 ([publishing.service.gov.uk](https://assets.publishing.service.gov.uk/media/68af256b969253904d1558e5/MSC_-_Core_Terms_-_E_W_-_Word_v2.2A_2025.DOCX)) | `43c7e8b70daf2177...` |
| `UK_Model_Services_Contract_Core_Terms_v2.2A.md` | MD | 191,880 B | **نعم (440 قطعة)** | تفريغ نصي مُعد محلياً من الأصل الحكومي البريطاني أعلاه لأغراض الفهرسة<br>Open Government Licence v3.0 | `4a3fb4b4184564d1...` |

---

## 2. النماذج القياسية مفتوحة المصدر (Open-Source Lawyer-Vetted Standards)

| اسم الملف | الصيغة | الحجم | مفهرس في KB؟ | المصدر والترخيص الموثق | بصمة SHA-256 |
| :--- | :---: | :---: | :---: | :--- | :--- |
| `Bonterms_Standard_Cloud_Terms_v1.0.md` | MD | 34,127 B | **نعم (75 قطعة)** | **Bonterms Open Source Contracts** ([GitHub](https://raw.githubusercontent.com/Bonterms/Cloud-Terms/main/Cloud-Terms.md)) — **CC BY 4.0** صريح في الوثيقة | `c6eca31d1267bc48...` |
| `Bonterms_Standard_Cloud_Terms_v1.0.pdf` | PDF | 236,100 B | لا (أصل PDF ورفع) | النسخة PDF الرسمية من Bonterms Cloud Terms v1.0 — **CC BY 4.0** | `da1b863844e360c2...` |
| `Bonterms_Mutual_NDA_v1.0.md` | MD | 7,707 B | **نعم (19 قطعة)** | **Bonterms Open Source Contracts** ([GitHub](https://raw.githubusercontent.com/Bonterms/Mutual-NDA/main/Mutual-NDA.md)) — **CC BY 4.0** صريح في الوثيقة | `f8657f44186a3c19...` |
| `Bonterms_Mutual_NDA_v1.0.pdf` | PDF | 151,156 B | لا (أصل PDF ورفع) | النسخة PDF الرسمية من Bonterms Mutual NDA v1.0 — **CC BY 4.0** | `7f92b9d136f39f6d...` |
| `Bonterms_Professional_Services_Agreement_v1.2.md` | MD | 42,842 B | **نعم (96 قطعة)** | **Bonterms Open Source Contracts** ([GitHub](https://raw.githubusercontent.com/Bonterms/Professional-Services-Agreement/main/Professional-Services-Agreement%20V1.2.md)) — **CC BY 4.0** | `7b1569a1e5e62762...` |
| `Bonterms_Professional_Services_Agreement_v1.2.pdf` | PDF | 356,673 B | لا (أصل PDF) | النسخة PDF الرسمية من Bonterms PSA v1.2 — **CC BY 4.0** | `eb02de92a1a65b39...` |

---

## 3. النماذج المجتمعية الاسترشادية والمستندات التجريبية (Community & Experimental)

### أ) نماذج مجتمعية استرشادية باللغة العربية (Community Advisory Templates — ليست وثائق حكومية)

| اسم الملف | الصيغة | الحجم | مفهرس في KB؟ | المصدر والملاحظات التنظيمية | بصمة SHA-256 |
| :--- | :---: | :---: | :---: | :--- | :--- |
| `Saudi_Digital_Solutions_Service_Contract.md` | MD | 36,009 B | **نعم (51 قطعة)** | مستودع مجتمعي على GitHub (`mustafaeida/devLegal-arabic-framework`) — **لا يوجد ملف LICENSE صريح (HTTP 404)**. يضم 19 بنداً مرقماً + 4 بنود `(مكرر)` = 23 قسماً. يحدد **المحكمة التجارية بالرياض** في البند الثامن (إشارة نظام المعاملات المدنية وردت في README المستودع فقط وليس داخل نص العقد). | `ee9a1522b4c6595a...` |
| `Saudi_Digital_Solutions_Service_Contract_v1.0.0.md` | MD | 29,202 B | **نعم (40 قطعة)** | النسخة الأرشيفية السابقة v1.0.0 من نفس المستودع المجتمعي، مُستخدمة لاختبار مقارنة إصدارات العقود. | `9bc929a6c5607095...` |
| `Saudi_Software_Delivery_Acceptance_Protocol.md` | MD | 5,188 B | **نعم (10 قطع)** | نموذج محضر استلام استرشادي من نفس المستودع المجتمعي لأغراض الاختبار. | `0be5ae70470747a8...` |
| `Scope_Management_and_Software_Amendments_Guide.md` | MD | 8,905 B | **نعم (12 قطعة)** | دليل استرشادي مجتمعي لإدارة النطاق وطلبات التغيير البرمجية. | `216c6b481ff71b96...` |

### ب) مستندات تجريبية مصممة لاختبارات الرفع المباشر (Experimental QA Upload Fixtures)

| اسم الملف | المسار | الصيغة | الحجم | مفهرس في KB؟ | الغرض الاختباري | بصمة SHA-256 |
| :--- | :--- | :---: | :---: | :---: | :--- | :--- |
| `Experimental_Test_Contract_Upload.pdf` | `evaluation/fixtures/` | PDF | 1,592 B | لا | مستند اختباري مصمم محلياً بأرقام فريدة (`EXP-PDF-2026-8842`, `485,000 SAR`) لإثبات عمل `Document Extractor` عبر واجهة Publish بشكل مستقل عن قاعدة المعرفة. | `46915563c561673a...` |
| `Experimental_Test_Service_Agreement_Upload.docx` | `evaluation/fixtures/` | DOCX | 37,393 B | لا | مستند اختباري ثنائي اللغة مع جدول (`EXP-DOCX-2026-7731`, `320,000 SAR`, `2027-06-30`) لإثبات استخلاص نصوص وجداول DOCX عبر واجهة Publish. | `dee1888897212271...` |
| `Experimental_Test_Arabic_Contract_Upload.pdf` | `evaluation/fixtures/` | PDF | 90,975 B | لا | عقد عربي تجريبي بالكامل (`EXP-AR-2026-091`, `240,000 ريال سعودي`, غرامة `1,500 ريال/أسبوع بحد 12%`, سجل ضريبي فارغ) لاختبار استخراج النصوص العربية عبر Publish PDF Upload. | `0adbc7ae66ef2411...` |

---

## ملخص إجمالي لقاعدة المعرفة (Baseera Docs)
- **إجمالي الملفات المفهرسة في Weaviate:** **8 ملفات Markdown** بإجمالي **457 مقطعاً مترابطاً** (`433` مقطعاً للـ 7 وثائق النشطة في `Baseera Docs — Evaluation Knowledge` مع Section-Aware Coalesced Chunking + `24` مقطعاً معزولة في `Baseera Docs — Legacy Draft v1.0.0` للمقارنة فقط؛ محدّث من `743` شظية أولية في `v1.0.0`/`v1.1.0`).
- **إجمالي الأصول المرجعية ومرفقات الاختبار (PDF / DOCX غير المفهرسة في KB):** **7 ملفات** (5 PDF + 2 DOCX).

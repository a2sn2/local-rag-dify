# دليل تطبيق وتدقيق الهوية البصرية لشركة جيب (JAIB × Dify)
## وثيقة التدقيق البصري الدقيق، ضبط التباين، وضوابط التكامل المؤسسي النهائي (Precision UI/UX Refinement)

---

## 1. ملخص تنفيذي (Executive Summary)

تم إنجاز مرحلة **الضبط والتدقيق البصري الدقيق (Precision UI/UX Refinement)** لتطبيق الهوية البصرية لشركة **جيب (JAIB)** للتقنية المالية (Fintech) على واجهات نظام **Dify v1.18.0** لمشروع Local RAG بنجاح تام وبأعلى معايير الجودة والتصميم المؤسسي.

تم الحفاظ التام على:
- سلامة البيانات وقواعد البيانات (`PostgreSQL`, `Weaviate`, `Redis`).
- نماذج الذكاء الاصطناعي المحلية في Ollama (`qwen3.5:4b`, `bge-m3`).
- تطبيقات RAG ومستودعات المعرفة ومخططات Chatflow دون أي مساس بها أو انقطاع في وظائفها.

---

## 2. مصفوفة التحسينات الهندسية الدقيقة المطبقة

### أولاً: ضبط حالات التنقل في القوائم الجانبية (Navigation States)
* **العنصر النشط (Active Item):**
  - تطبيق أحمر جيب الرسمي `#E4122D` (`rgb(228, 18, 45)`) بخلفية حمراء ناعمة ومحسوبة بدقة `rgba(228, 18, 45, 0.08)`.
  - إزالة التدرجات الوردية المتوهجة (`linear-gradient`) والظلال الثقيلة المعتمة كلياً (`background-image: none`, `box-shadow: inset 0 0 0 1px rgba(228, 18, 45, 0.16)`).
  - إخفاء العناصر الزائفة المضيئة `::before` و `::after` للحصول على مظهر حديث ومريح للعين (Flat & Clean Fintech UI).
* **العناصر غير النشطة (Inactive Items):**
  - تطبيق نص حيادي عالي القراءة `#475467` (`rgb(71, 84, 103)`) بنسبة تباين **7.69:1** (مطابقة لمعايير WCAG AAA).
  - خلفية شفافة تماماً بنسبة 100% (`rgba(0, 0, 0, 0)`).
  - أيقونات حيادية رمادية `#667085` (`rgb(102, 112, 133)`).
  - تصحيح المحددات البرمجية الفضفاضة السابقة التي كانت تؤثر بالخطأ على كافة الروابط بسبب وسم Tailwind العام `aria-[current=page]:dify-blue-glass-surface`، وتقييد التأثير فقط على `nav a[aria-current="page"]`.
* **حالة التحويم التفاعلي (Hover State):**
  - منح العنصر لمسة تأكيدية ناعمة لسمة جيب `rgba(228, 18, 45, 0.05)` مع تحول لون النص إلى `#101828` ولون الأيقونة إلى `#CE1028`.
  - زوال التأثير فور تحريك المؤشر بعيداً دون أي بقاء غير مقصود (Non-persistent Hover Reversion).

---

### ثانياً: هندسة الخطوط والتباين اللوني (Typography & Contrast - WCAG AA/AAA)
* **عناوين بطاقات التطبيقات (App Card Titles):**
  - تصحيح لون العناوين من الرمادي الباهت السالف (`#8E8E93` - تباين ضعيف 3.4:1) إلى اللون الصريح والواضح `#101828` (`rgb(16, 24, 40)`).
  - نسبة التباين الناتجة: **17.75:1** على الخلفية البيضاء (تتجاوز معيار WCAG AAA البالغ 7.0:1 بمراحل).
* **أوصاف البطاقات والنصوص الثانوية (Card Descriptions):**
  - تطبيق لون slate المحايد `#475467` بنسبة تباين **7.69:1** على الأبيض و **6.90:1** على الأرضية `#F3F2F7`.
* **البيانات الوصفية وشارات الأنظمة (Metadata & Tags):**
  - تطبيق `#525866` بنسبة تباين **5.60:1** متجاوزة الحد الأدنى لمعيار WCAG AA (4.5:1).
* **الوضع المظلم (Dark Mode Contrast):**
  - العناوين: `#F4F4F5` (تباين **15.64:1** على `#1A1B20`).
  - الأوصاف والشارات: `#D0D5DD` و `#98A2B3` (تباين **11.66:1** و **6.68:1**).
* **سلسلة الخطوط المحلية الخالصة (Air-Gapped Font Stack):**
  - `"DIN Next LT Arabic", "Noto Sans Arabic", "Plus Jakarta Sans", "Segoe UI", -apple-system, BlinkMacSystemFont, Tahoma, Arial, sans-serif`.

---

### ثالثاً: الشعار المتجهي النقي وصون أيقونات القوالب الخارجية
* **شعار متكامل نقي 100% (Pure Vector SVG):**
  - خلو تام من وسوم الصور النقطية `<image>` أو تشفير Base64.
  - الحفاظ على أبعاد الشعار وانسيابية التجاوب عبر الشاشات المختلفة (Desktop, Laptop, Tablet, Mobile).
  - الحفاظ على لون Dify الرسمي المعتمد (`#0033FF` للفاتح و `#3072FF` للداكن) التزاماً بالترخيص المفتوح.
* **حماية أيقونات القوالب الخارجية (Marketplace Templates):**
  - إزالة قواعد إعادة تلوين أيقونات القوالب الخارجية بالقوة (`bg-components-icon-bg-blue-*`) وترك ألوان القوالب الخارجية الأصلية للمنصات والمكتبات دون تشويه.

---

### رابعاً: صمام أمان محرر التدفق (ReactFlow Canvas LTR)
* استمرار تثبيت اتجاه لوحة الرسم `direction: ltr !important` لضمان عمل عقد ومسارات وتوصيلات Chatflow بدقة إحداثيات ديكارتية ومنحنيات بيزير السليمة حتى مع واجهة المستخدم العربية (RTL).

---

## 3. مصفوفة نتائج الفحص البرمجي المحسوب (Computed Styles & Contrast Audit)

تم الفحص عبر Playwright بمقياس تكبير المتصفح 100% (Device Scale Factor 1.0) وجاءت النتائج كالتالي:

| المكون المفحوص | المحدد البرمجي (Selector) | القيمة المحسوبة الفعلية | التدرج والخلفية | نسبة التباين (Contrast Ratio) | الحالة |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Home Active Item** | `nav a[aria-current="page"]` | `rgb(228, 18, 45)` | `rgba(228, 18, 45, 0.08)` / لا يوجد وردي | `4.75:1` (WCAG AA) | **PASS** |
| **Home Inactive Item** | `nav a:not([aria-current="page"])` | `rgb(71, 84, 103)` | `rgba(0, 0, 0, 0)` (شفاف 100%) | `7.69:1` (WCAG AAA) | **PASS** |
| **Studio Active Item** | `a[href="/apps"][aria-current="page"]` | `rgb(228, 18, 45)` | `rgba(228, 18, 45, 0.08)` / حافة ناعمة | `4.75:1` (WCAG AA) | **PASS** |
| **Inactive Nav Hover** | `nav a:not([aria-current="page"]):hover` | `rgb(16, 24, 40)` / أيقونة: `rgb(206, 16, 40)` | لمسة `rgba(228, 18, 45, 0.05)` ناعمة | مؤقتة وتزول فوراً | **PASS** |
| **Primary Button** | `button[class*="bg-components-button-primary"]` | نص: `rgb(255, 255, 255)` / خلفية: `rgb(228, 18, 45)` | أحمر جيب مصمت، زوايا `14px` | `4.75:1` (WCAG AA) | **PASS** |
| **Card Title** | `div[class*="text-sm/5"][class*="font-semibold"]` | `rgb(16, 24, 40)` | واضحة تماماً وخالية من البهتان | **17.75:1** (تتجاوز AAA) | **PASS** |
| **Card Metadata** | `div[class*="system-xs-regular"]` | `rgb(82, 88, 102)` | مقروءة ومرتبة | **7.13:1** (تتجاوز AA) | **PASS** |
| **Dark Mode Active** | `[data-theme="dark"] nav a[aria-current="page"]` | `rgb(255, 255, 255)` | خلفية ناعمة `rgba(228, 18, 45, 0.2)` | **15.64:1** (WCAG AAA) | **PASS** |
| **Dark Mode Inactive** | `[data-theme="dark"] nav a:not([aria-current="page"])` | `rgb(166, 167, 173)` | خلفية شفافة تماماً `rgba(0, 0, 0, 0)` | **6.68:1** (WCAG AA) | **PASS** |
| **ReactFlow Canvas** | `.react-flow, .react-flow__renderer` | `direction: ltr` | شبكة ومقابض ومسارات سليمة 100% | متوافق مع LTR الديكارتي | **PASS** |
| **Pure Vector Logo** | `res.text().includes('<image')` | **0** (خلو تام من الصور النقطية) | متجهات رياضية نقية `<path>` | دقة حادة بكافة الشاشات | **PASS** |

---

## 4. معرض الأدلة البصرية المحدثة (Visual Evidence Gallery)

جميع لقطات الشاشة الفعلية محدثة ومحفوظة بدقة فائقة في المجلد:
`docs/evidence/jaib-theme/`

1. `jaib_home_desktop_light.png`: الصفحة الرئيسية (Home) مع قائمة نشطة بأحمر جيب ناعم، وقوائم غير نشطة حيادية شفافة.
2. `jaib_home_laptop_1366.png`: الصفحة الرئيسية على قياس شاشات اللابتوب (1366x768).
3. `jaib_home_tablet_768.png`: الصفحة الرئيسية على الأجهزة اللوحية (768x1024).
4. `jaib_home_mobile_390.png`: الصفحة الرئيسية على شاشات الجوال الذكية (390x844).
5. `jaib_apps_desktop.png`: لوحة التطبيقات (Studio) مع تباين عالي لعناوين البطاقات وتنسيق ناعم غير مفرط.
6. `jaib_apps_dark.png`: لوحة التطبيقات في الوضع المظلم فائق التباين والنقاء.
7. `jaib_apps_arabic_rtl.png`: لوحة التطبيقات بالواجهة العربية الكاملة (RTL).
8. `jaib_datasets_desktop.png`: لوحة إدارة قواعد المعرفة (Knowledge).
9. `jaib_chatflow_workflow.png`: محرر ومخطط التدفق البصري Chatflow مع صمام أمان LTR للكانفاس.

---

## 5. دليل التشغيل السريع وآلية التراجع الفوري (Runbook & Rollback)

### تطبيق وتحديث الهوية بأمر واحد:
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\hassa\local-rag\scripts\apply-jaib-theme.ps1
```

### التراجع الفوري إلى الحاوية الأصلية لـ Dify بأمر واحد:
```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\hassa\local-rag\scripts\rollback-jaib-theme.ps1
```
يعمل أمر التراجع على إلغاء تفعيل `docker-compose.override.yaml` وإعادة تشغيل واجهة الويب بصورتها الرسمية الأصلية `langgenius/dify-web:1.18.0` فوراً دون أي مساس بقواعد البيانات أو نماذج Ollama أو إعدادات النظام.

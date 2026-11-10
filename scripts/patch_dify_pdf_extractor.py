import os
import re
import shutil

TARGET = "/app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py"
BACKUP = TARGET + ".orig_v1_18"

if not os.path.exists(BACKUP):
    shutil.copy2(TARGET, BACKUP)
    print(f"Backed up original node.py -> {BACKUP}")
else:
    # Always start cleanly from pristine original before applying v1.3 patch (idempotent!)
    shutil.copy2(BACKUP, TARGET)
    print(f"Restored pristine baseline from {BACKUP}")

with open(TARGET, "r", encoding="utf-8") as f:
    src = f.read()

HELPER_MODULE = '''
def _count_torn_arabic_lines(text: str) -> int:
    """Count fragmented 1-3 char Arabic lines caused by PDFium ligature splits."""
    bad = 0
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            continue
        if len(s) <= 3 and any("\\u0600" <= c <= "\\u06FF" or "\\uFE70" <= c <= "\\uFEFF" for c in s):
            bad += 1
        elif len(s) == 1 and 0x064B <= ord(s[0]) <= 0x065F:
            bad += 1
    return bad


def _repair_arabic_kerning_spaces(text: str) -> str:
    """Repair safe intraword Arabic kerning splits (single-char orphans & 'ال ') without altering meaning."""
    import re
    import unicodedata

    text = unicodedata.normalize("NFKC", text)
    # 1) Standalone single Arabic letters broken across kerning gap (e.g. 'ف ي' -> 'في')
    text = re.sub(
        r"(?<![\\u0621-\\u064A])([بتثجحخدذرزسشصضطظعغفقكلمنهي])\\s+(ي|ى|ن|ح|خ|ت|ة|م|ر|ل|ز|ك|هـ?|ا)(?![\\u0621-\\u064A])",
        r"\\1\\2",
        text,
    )
    # 2) Isolated trailing single consonant/vowel separated from preceding Arabic word ('أمن ي' -> 'أمني', 'تاري خ' -> 'تاريخ')
    text = re.sub(
        r"([\\u0621-\\u064A]{2,}[\\u064B-\\u065F]*)\\s+([يتنحخزرصضطظعغفقكلمههةى])(?=\\s|[،؛.:\\n\\)\\]]|$)",
        r"\\1\\2",
        text,
    )
    # 3) Detached tanween fath + alif ('وفق ًا' -> 'وفقًا')
    text = re.sub(r"([\\u0621-\\u064A])\\s+([\\u064B-\\u065F]+ا?)(?=\\s|[،؛.:\\n\\)\\]]|$)", r"\\1\\2", text)
    # 4) Detached definite prefix 'ال ' ('ال تقنية' -> 'التقنية')
    text = re.sub(r"(?<![\\u0621-\\u064A])(ال)\\s+([\\u0621-\\u064A]{2,})", r"\\1\\2", text)
    return text


def _call_local_ollama_vision(png_bytes: bytes, prompt_text: str) -> str:
    """100% local Ollama Vision OCR fallback using qwen3.5:4b on host.docker.internal:11434."""
    import base64
    import urllib.request

    b64 = base64.b64encode(png_bytes).decode("ascii")
    payload = {
        "model": "qwen3.5:4b",
        "messages": [{"role": "user", "content": prompt_text, "images": [b64]}],
        "stream": False,
        "think": True,
        "options": {"num_ctx": 16384, "temperature": 0.0, "num_predict": 450},
    }
    req = urllib.request.Request(
        "http://host.docker.internal:11434/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        res = json.loads(resp.read().decode("utf-8"))
    return (res.get("message", {}).get("content") or "").strip()


def _extract_pypdf_pages_coords(file_content: bytes) -> tuple[list[str], float, float]:
    """Coordinate-aware PDF text reconstruction supporting RTL Arabic lines and Y-baseline jitter."""
    import re
    import unicodedata

    pdf_reader = pypdf.PdfReader(io.BytesIO(file_content))
    pages_out: list[str] = []
    p1_top_empty = 0.0
    p1_bot_empty = 0.0
    try:
        for pno, page in enumerate(pdf_reader.pages, 1):
            fragments: list[tuple[float, float, float, str]] = []

            def visitor(text, cm, tm, font_dict, font_size):
                if not text:
                    return
                t_clean = text.replace("\\r", "")
                if not t_clean.strip():
                    return
                x = cm[0] * tm[4] + cm[2] * tm[5] + cm[4]
                y = cm[1] * tm[4] + cm[3] * tm[5] + cm[5]
                fs = float(font_size or 11.0)
                fragments.append((y, x, fs, t_clean.strip("\\n")))

            raw_probe = page.extract_text() or ""
            has_arabic = any("\\u0600" <= ch <= "\\u06FF" or "\\uFE70" <= ch <= "\\uFEFF" for ch in raw_probe)
            sw = 420.0 if has_arabic else 200.0
            page.extract_text(space_width=sw, visitor_text=visitor)

            if pno == 1:
                page_h = float(page.mediabox.height or 842.0)
                ys = [it[0] for it in fragments]
                if ys and page_h > 0:
                    p1_top_empty = max(0.0, (page_h - max(ys)) / page_h)
                    p1_bot_empty = max(0.0, min(ys) / page_h)

            fragments.sort(key=lambda it: -it[0])
            lines_bins: list[dict[str, Any]] = []
            for y, x, fs, txt in fragments:
                tol = max(7.0, fs * 0.85)
                placed = False
                for b in lines_bins:
                    if abs(b["y"] - y) <= tol:
                        b["items"].append((y, x, fs, txt))
                        placed = True
                        break
                if not placed:
                    lines_bins.append({"y": y, "items": [(y, x, fs, txt)]})

            reconstructed_lines: list[str] = []
            for b in lines_bins:
                items = b["items"]
                line_all = "".join(it[3] for it in items)
                ar_cnt = sum(1 for c in line_all if "\\u0600" <= c <= "\\u06FF" or "\\uFE70" <= c <= "\\uFEFF")
                en_cnt = sum(1 for c in line_all if "A" <= c <= "Z" or "a" <= c <= "z")
                if ar_cnt >= en_cnt:
                    items_sorted = sorted(items, key=lambda it: -it[1])
                    parts: list[str] = []
                    for _, _, _, itxt in items_sorted:
                        s = itxt.strip()
                        if not s:
                            continue
                        if all(0x064B <= ord(c) <= 0x065F or ord(c) == 0x0670 for c in s):
                            if parts:
                                parts[-1] += s
                            continue
                        if not parts:
                            parts.append(s)
                        elif itxt.startswith(" ") or parts[-1].endswith(" "):
                            parts.append(s)
                        else:
                            parts[-1] = parts[-1] + s
                    line = " ".join(p.strip() for p in parts if p.strip())
                else:
                    items_sorted = sorted(items, key=lambda it: it[1])
                    line = " ".join(it[3].strip() for it in items_sorted if it[3].strip())
                line = re.sub(r"\\s{2,}", " ", line).strip()
                line = re.sub(r"^(\\d+\\s*[)\\-\\.])\\s*:\\s*(.+)$", r"\\1 \\2:", line)
                if line:
                    reconstructed_lines.append(_repair_arabic_kerning_spaces(line))
            pages_out.append("\\n".join(reconstructed_lines))
        return pages_out, p1_top_empty, p1_bot_empty
    finally:
        pdf_reader.close()


def _apply_local_window_guard(text: str) -> str:
    """Keep extracted text inside the local 16K LLM context window with honest overflow disclosure."""
    weighted = sum(2 if ("\\u0600" <= c <= "\\u06FF" or "\\uFE70" <= c <= "\\uFEFF") else 1 for c in text)
    if weighted <= 55000:
        return text
    acc = 0
    cut = len(text)
    for idx, ch in enumerate(text):
        acc += 2 if ("\\u0600" <= ch <= "\\u06FF" or "\\uFE70" <= ch <= "\\uFEFF") else 1
        if acc >= 28000:
            cut = idx
            break
    nl = text.rfind("\\n", max(0, cut - 500), cut)
    if nl > cut // 2:
        cut = nl
    rem = len(text) - cut
    banner = (
        "[⚠️ تنبيه حد النافذة المحلية / LOCAL 16K WINDOW LIMIT EXCEEDED]\\n"
        f"إجمالي طول النص المستخرج من هذا الملف: {len(text):,} حرفاً، وهو يتجاوز سعة النافذة المحلية للتحليل دفعة واحدة (16,384 رمزاً).\\n"
        f"يعرض النظام الجزء الافتتاحي فقط ({cut:,} حرفاً)، بينما تبقى {rem:,} حرفاً من باقي المستند غير معروضة في هذه النافذة.\\n"
        "أجب حصراً من البنود الظاهرة أدناه وأفصح للمستخدم بصدق عن الجزء المتبقي غير الظاهر دون تخمين.\\n"
        "[/تنبيه حد النافذة المحلية]\\n\\n"
    )
    return banner + text[:cut]


def _deduplicate_pdf_headers_footers(pages: list[str]) -> list[str]:
    """Remove boilerplate single-line headers/footers repeated across most pages while keeping headings."""
    import math
    import re
    from collections import Counter

    if len(pages) < 3:
        return pages
    thresh = max(3, math.ceil(len(pages) * 0.6))
    first_lines = Counter()
    last_lines = Counter()
    split_pages = [p.splitlines() for p in pages]
    for lns in split_pages:
        non_empty = [ln.strip() for ln in lns if ln.strip()]
        if non_empty:
            first_lines[non_empty[0]] += 1
            last_lines[non_empty[-1]] += 1
    rep_first = {k for k, v in first_lines.items() if v >= thresh and len(k) < 100 and not re.match(r"^(\\d+|البند|Clause|Section)\\b", k)}
    rep_last = {k for k, v in last_lines.items() if v >= thresh and len(k) < 100 and not re.match(r"^(\\d+|البند|Clause|Section)\\b", k)}
    if not rep_first and not rep_last:
        return pages

    cleaned = []
    seen_first = set()
    for lns in split_pages:
        out_lns = []
        ne_indices = [idx for idx, ln in enumerate(lns) if ln.strip()]
        first_idx = ne_indices[0] if ne_indices else -1
        last_idx = ne_indices[-1] if ne_indices else -1
        for idx, ln in enumerate(lns):
            s = ln.strip()
            if idx == first_idx and s in rep_first:
                if s in seen_first:
                    continue
                seen_first.add(s)
            elif idx == last_idx and s in rep_last:
                continue
            out_lns.append(ln)
        cleaned.append("\\n".join(out_lns))
    return cleaned


def _extract_text_from_pdf(file_content: bytes) -> str:
    import unicodedata

    try:
        with (
            _PDFIUM_LOCK,
            pypdfium2.PdfDocument(
                io.BytesIO(file_content),
                autoclose=True,
            ) as pdf_document,
        ):
            pdfium_pages: list[str] = []
            for page in pdf_document:
                try:
                    tp = page.get_textpage()
                    try:
                        pdfium_pages.append(tp.get_text_range() or "")
                    finally:
                        tp.close()
                finally:
                    page.close()
    except Exception as e:
        msg = f"Failed to extract text from PDF: {e!s}"
        raise TextExtractionError(msg) from e

    pypdf_pages: list[str] = []
    p1_top_empty = 0.0
    p1_bot_empty = 0.0
    try:
        pypdf_pages, p1_top_empty, p1_bot_empty = _extract_pypdf_pages_coords(file_content)
    except Exception:
        logger.debug("Coordinate pypdf extraction failed; using PDFium baseline", exc_info=True)

    num_pages = max(len(pdfium_pages), len(pypdf_pages))
    if num_pages == 0:
        return ""

    chosen_pages: list[str] = []
    for idx in range(num_pages):
        p_raw = pdfium_pages[idx] if idx < len(pdfium_pages) else ""
        c_raw = pypdf_pages[idx] if idx < len(pypdf_pages) else ""
        torn_pdfium = _count_torn_arabic_lines(p_raw)
        torn_pypdf = _count_torn_arabic_lines(c_raw)

        # Prefer clean PDFium unless PDFium shattered Arabic glyphs/ligatures or returned empty
        if len(p_raw.strip()) >= 40 and (torn_pdfium <= 1 or (torn_pdfium <= torn_pypdf and len(c_raw.strip()) < 40)):
            page_txt = unicodedata.normalize("NFKC", p_raw).strip()
        elif len(c_raw.strip()) >= 40:
            page_txt = c_raw.strip()
        elif len(p_raw.strip()) > 0:
            page_txt = unicodedata.normalize("NFKC", p_raw).strip()
        else:
            page_txt = ""

        # Local Vision OCR fallback ONLY for scanned/image-only pages with <40 chars extracted
        if len(page_txt) < 40:
            try:
                with (
                    _PDFIUM_LOCK,
                    pypdfium2.PdfDocument(io.BytesIO(file_content), autoclose=True) as doc_ocr,
                ):
                    if idx < len(doc_ocr):
                        pil_pg = doc_ocr[idx].render(scale=1.6).to_pil().convert("L")
                        w, h = pil_pg.size
                        dark = sum(1 for px in pil_pg.getdata() if px < 235) / max(1, w * h)
                        if dark > 0.01:
                            buf = io.BytesIO()
                            pil_pg.save(buf, format="PNG")
                            ocr_txt = _call_local_ollama_vision(
                                buf.getvalue(),
                                "انسخ النص الموجود في هذه الصفحة حرفياً بالترتيب الصحيح دون تلخيص أو إضافة.",
                            )
                            if ocr_txt:
                                page_txt = f"[استخراج بصري محلي OCR]\\n{ocr_txt}"
            except Exception:
                logger.debug("Local scanned-page OCR fallback failed on page %d", idx + 1, exc_info=True)

        chosen_pages.append(page_txt)

    chosen_pages = _deduplicate_pdf_headers_footers(chosen_pages)

    # Check Page 1 header/footer vector graphics missing from text stream -> 1 fast cropped banner scan
    banner_meta = ""
    if (p1_top_empty >= 0.11 or p1_bot_empty >= 0.08) and len(chosen_pages) >= 1:
        try:
            with (
                _PDFIUM_LOCK,
                pypdfium2.PdfDocument(io.BytesIO(file_content), autoclose=True) as doc_ban,
            ):
                pil_p1 = doc_ban[0].render(scale=1.5).to_pil().convert("RGB")
                gray = pil_p1.convert("L")
                w, h = gray.size
                top_h = max(1, int(h * min(0.18, max(0.10, p1_top_empty + 0.02))))
                bot_h = max(1, int(h * min(0.11, max(0.06, p1_bot_empty + 0.02))))
                top_crop = gray.crop((0, 0, w, top_h))
                bot_crop = gray.crop((0, h - bot_h, w, h))
                top_dark = sum(1 for px in top_crop.getdata() if px < 235) / max(1, w * top_h)
                bot_dark = sum(1 for px in bot_crop.getdata() if px < 235) / max(1, w * bot_h)
                if (p1_top_empty >= 0.11 and top_dark >= 0.045) or (p1_bot_empty >= 0.08 and bot_dark >= 0.12):
                    from PIL import Image
                    top_rgb = pil_p1.crop((0, 0, w, top_h))
                    bot_rgb = pil_p1.crop((0, h - bot_h, w, h))
                    banner = Image.new("RGB", (w, top_h + bot_h), (255, 255, 255))
                    banner.paste(top_rgb, (0, 0))
                    banner.paste(bot_rgb, (0, top_h))
                    bbuf = io.BytesIO()
                    banner.save(bbuf, format="PNG")
                    vis_hdr = _call_local_ollama_vision(
                        bbuf.getvalue(),
                        "انظر إلى صورة ترويسة وتذييل الصفحة الأولى فقط. استخرج بدقة اسم الشركة أو الجهة بالعربية (بشكل سليم من اليمين لليسار) والإنجليزية، وعنوان الوثيقة والموقع الإلكتروني إن ظهرت بصرياً دون تخمين.",
                    )
                    if vis_hdr:
                        banner_meta = (
                            "[بيانات الترويسة وهوية المستند المستخلصة بصرياً (Metadata من الصفحة 1):\\n"
                            f"{vis_hdr}\\n]\\n\\n"
                        )
        except Exception:
            logger.debug("Page 1 visual letterhead check failed", exc_info=True)

    formatted_pages = [
        f"--- [صفحة {i} من {num_pages}] ---\\n{pt}" if num_pages > 1 else pt
        for i, pt in enumerate(chosen_pages, 1)
    ]
    return banner_meta + "\\n\\n".join(formatted_pages)
'''

# 1. Tag every extracted file with its filename in DocumentExtractorNode._run so multi-doc uploads never lose file attribution
old_list_call = '''                extracted_text_list = [
                    _extract_text_from_file(
                        self._http_client,
                        file,
                        unstructured_api_config=self._unstructured_api_config,
                    )
                    for file in value
                ]'''
new_list_call = '''                extracted_text_list = [
                    _apply_local_window_guard(
                        f"[اسم الملف المرفق: {file.filename or 'document'}]\\n"
                        + _extract_text_from_file(
                            self._http_client,
                            file,
                            unstructured_api_config=self._unstructured_api_config,
                        )
                    )
                    for file in value
                ]'''
assert old_list_call in src, "old_list_call not found"
src = src.replace(old_list_call, new_list_call, 1)

old_single_call = '''                extracted_text = _extract_text_from_file(
                    self._http_client,
                    value,
                    unstructured_api_config=self._unstructured_api_config,
                )'''
new_single_call = '''                extracted_text = _apply_local_window_guard(
                    f"[اسم الملف المرفق: {value.filename or 'document'}]\\n"
                    + _extract_text_from_file(
                        self._http_client,
                        value,
                        unstructured_api_config=self._unstructured_api_config,
                    )
                )'''
assert old_single_call in src, "old_single_call not found"
src = src.replace(old_single_call, new_single_call, 1)

# 2. Replace _extract_text_from_pdf function cleanly
old_pdf_fn = '''def _extract_text_from_pdf(file_content: bytes) -> str:
    try:
        text = _read_pdf_text_with_pdfium(file_content)
    except Exception as e:
        msg = f"Failed to extract text from PDF: {e!s}"
        raise TextExtractionError(msg) from e
    if text.strip():
        return text
    logger.debug("PDFium returned empty text for PDF; trying pypdf fallback")
    return _read_fallback_pdf_text(file_content, default_text=text)'''
assert old_pdf_fn in src, "old_pdf_fn not found"
src = src.replace(old_pdf_fn, HELPER_MODULE.strip(), 1)

with open(TARGET, "w", encoding="utf-8") as f:
    f.write(src)

print("Successfully patched", TARGET)


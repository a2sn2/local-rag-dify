"""Patcher for Dify v1.18.0 DocumentExtractorNode with universal Arabic PDF, OCR, cache, and Map-Reduce support.

Usage:
  1. Generate canonical patched node.py for Docker compose volume mount:
       python patch_dify_pdf_extractor.py --source orig_node.py --output docker/dify/patches/document_extractor_node.py
  2. Patch an unmounted container in-place (with .orig_v1_18 backup):
       python patch_dify_pdf_extractor.py
"""

from __future__ import annotations

import argparse
import os
import shutil

DEFAULT_TARGET = "/app/api/.venv/lib/python3.13/site-packages/graphon/nodes/document_extractor/node.py"

HELPER_MODULE = '''
_DOC_CACHE_DIR = os.environ.get("BASEERA_DOC_CACHE_DIR", "/app/api/storage/doc_cache")
_OCR_BOILERPLATE_RE = re.compile(
    r"^(?:إليك\\s+النص[^:\\n]*:|بناءً\\s+على\\s+الصورة[^:\\n]*:|"
    r"\\*{0,2}النص\\s+(?:العربي|الإنجليزي|المستخرج)[^\\n]*\\*{0,2}\\s*:?|"
    r"\\*{0,2}الأرقام[^\\n]*\\*{0,2}\\s*:?|بالترتيب\\s+من\\s+أعلى[^\\n]*:?)$",
    re.MULTILINE,
)


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


def _is_mojibake_char(ch: str) -> bool:
    """Detect non-Arabic glyph corruption produced by broken PDF /ToUnicode CMaps."""
    import unicodedata

    o = ord(ch)
    if 0x0100 <= o <= 0x052F or 0x1D00 <= o <= 0x1FFF or o == 0xFFFD:
        return True
    if unicodedata.category(ch) == "Mn" and not (0x0610 <= o <= 0x065F or o == 0x0670):
        return True
    return False


def _count_mojibake_chars(text: str) -> tuple[int, int]:
    """Return (mojibake_count, non_whitespace_count) for ToUnicode corruption detection."""
    if not text:
        return 0, 0
    bad = 0
    non_ws = 0
    for ch in text:
        if ch.isspace():
            continue
        non_ws += 1
        if _is_mojibake_char(ch):
            bad += 1
    return bad, non_ws


def _has_broken_cmap(text: str) -> bool:
    """True when PDF text layer has significant /ToUnicode CMap glyph corruption."""
    bad, non_ws = _count_mojibake_chars(text)
    return bad >= 12 or (non_ws >= 80 and (bad / max(1, non_ws)) > 0.015)


def _repair_arabic_kerning_spaces(text: str) -> str:
    """Repair safe intraword Arabic kerning splits without altering legal meaning."""
    import unicodedata

    text = unicodedata.normalize("NFKC", text)
    text = re.sub(
        r"(?<![\\u0621-\\u064A])([بتثجحخدذرزسشصضطظعغفقكلمنهي])\\s+(ي|ى|ن|ح|خ|ت|ة|م|ر|ل|ز|ك|هـ?|ا)(?![\\u0621-\\u064A])",
        r"\\1\\2",
        text,
    )
    text = re.sub(
        r"([\\u0621-\\u064A]{2,}[\\u064B-\\u065F]*)\\s+([يتنحخزرصضطظعغفقكلمههةى])(?=\\s|[،؛.:\\n\\)\\]]|$)",
        r"\\1\\2",
        text,
    )
    text = re.sub(r"([\\u0621-\\u064A])\\s+([\\u064B-\\u065F]+ا?)(?=\\s|[،؛.:\\n\\)\\]]|$)", r"\\1\\2", text)
    text = re.sub(r"(?<![\\u0621-\\u064A])(ال)\\s+([\\u0621-\\u064A]{2,})", r"\\1\\2", text)
    return text


def _estimate_qwen_tokens(text: str) -> int:
    """Estimate qwen3.5:4b token count accurately without over-penalizing clean Arabic."""
    if not text:
        return 0
    acc = 0.0
    for ch in text:
        if "\\u0600" <= ch <= "\\u06FF" or "\\uFE70" <= ch <= "\\uFEFF":
            acc += 0.36
        else:
            acc += 0.32
    return int(acc) + 16


def _call_local_ollama_chat(
    messages: list[dict[str, Any]],
    *,
    num_ctx: int = 4096,
    num_predict: int = 1100,
    timeout: int = 180,
) -> str:
    """Call local Ollama HTTP chat endpoint (100% local host.docker.internal:11434)."""
    import urllib.request

    ollama_url = os.environ.get("BASEERA_OLLAMA_CHAT_URL", "http://host.docker.internal:11434/api/chat")
    payload = {
        "model": os.environ.get("BASEERA_LOCAL_MODEL", "qwen3.5:4b"),
        "messages": messages,
        "stream": False,
        "think": False,
        "keep_alive": "15m",
        "options": {"num_ctx": num_ctx, "temperature": 0.0, "num_predict": num_predict},
    }
    req = urllib.request.Request(
        ollama_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        res = json.loads(resp.read().decode("utf-8"))
    return (res.get("message", {}).get("content") or "").strip()


def _call_local_ollama_vision(image_bytes: bytes, prompt_text: str, *, num_ctx: int = 3072, num_predict: int = 1100) -> str:
    """Run local multimodal OCR on rendered page image bytes."""
    import base64

    b64 = base64.b64encode(image_bytes).decode("ascii")
    return _call_local_ollama_chat(
        [{"role": "user", "content": prompt_text, "images": [b64]}],
        num_ctx=num_ctx,
        num_predict=num_predict,
        timeout=180,
    )


def _clean_ocr_output(text: str) -> str:
    """Strip occasional boilerplate preambles or formatting chatter added by Vision OCR."""
    cleaned = _OCR_BOILERPLATE_RE.sub("", text or "")
    cleaned = re.sub(r"\\n{3,}", "\\n\\n", cleaned)
    return cleaned.strip()


def _cache_read(cache_key: str) -> dict[str, Any] | None:
    if os.environ.get("BASEERA_DOC_CACHE_DISABLE") == "1":
        return None
    try:
        path = os.path.join(_DOC_CACHE_DIR, f"{cache_key}.json")
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        logger.debug("Doc cache read miss/error for %s", cache_key, exc_info=True)
    return None


def _cache_write(cache_key: str, data: dict[str, Any]) -> None:
    if os.environ.get("BASEERA_DOC_CACHE_DISABLE") == "1":
        return
    try:
        os.makedirs(_DOC_CACHE_DIR, exist_ok=True)
        path = os.path.join(_DOC_CACHE_DIR, f"{cache_key}.json")
        tmp_path = f"{path}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp_path, path)
    except Exception:
        logger.debug("Doc cache write failed for %s", cache_key, exc_info=True)


def _extract_numeric_latin_hints(raw_txt: str) -> str:
    """Extract clean numbers, percentages, URLs, and Latin symbols without broken Unicode glyphs."""
    tokens = re.findall(r"(?:www\\.[A-Za-z0-9._-]+|[A-Za-z0-9\\u0660-\\u0669٪%.,:/()\\-]{2,}|[\\u0660-\\u0669\\d]+)", raw_txt or "")
    seen: set[str] = set()
    out: list[str] = []
    for tok in tokens:
        t = tok.strip(".,:/()-")
        if t and not any(_is_mojibake_char(c) for c in t) and t not in seen:
            seen.add(t)
            out.append(t)
    return " | ".join(out[:80])


def _render_pdf_page_ocr(doc_ocr: Any, page_idx: int, raw_hint: str, *, broken_cmap: bool) -> str:
    """Render one PDF page to grayscale JPEG and transcribe cleanly via local Vision OCR with zero mojibake echo."""
    safe_hints = _extract_numeric_latin_hints(raw_hint)
    for scale, use_raw_draft in ((1.50, True), (1.65, False), (1.85, False)):
        pil_pg = doc_ocr[page_idx].render(scale=scale).to_pil().convert("L")
        w, h = pil_pg.size
        dark = sum(1 for px in pil_pg.getdata() if px < 238) / max(1, w * h)
        if dark <= 0.004:
            return ""
        buf = io.BytesIO()
        pil_pg.save(buf, format="JPEG", quality=88)
        if broken_cmap and use_raw_draft and raw_hint.strip():
            prompt = (
                "استخرج النص العربي والإنجليزي والأرقام في صورة هذه الصفحة حرفياً ومباشرة بالترتيب من أعلى لأسفل ومن اليمين لليسار "
                "دون أي مقدمة أو تعليق أو عناوين مثل 'إليك النص' أو 'النص العربي' أو 'الأرقام'.\\n"
                "ملاحظة: النص الأولي أدناه مأخوذ من نفس الصفحة وبه بعض الرموز التالفة؛ اعتمد على الصورة لقراءة الكلمات العربية "
                "وأدوات النفي (لا / لم / لن / يمنع / يغلق) والجداول بدقة، واستعن بالأرقام الواضحة والأسماء السليمة في النص الأولي عند تطابقها مع الصورة:\\n"
                f"{raw_hint}"
            )
        elif safe_hints:
            prompt = (
                "اقرأ صورة هذه الصفحة واستخرج كل النص العربي والإنجليزي والأرقام حرفياً ومباشرة بالترتيب من اليمين لليسار ومن أعلى لأسفل، "
                "دون أي مقدمة أو تعليق أو تلخيص أو عناوين مضافة. حافظ على الجداول وأدوات النفي وعناوين المواد والأبواب بدقة.\\n"
                f"أرقام ورموز مرجعية للتدقيق فقط: {safe_hints}"
            )
        else:
            prompt = (
                "اقرأ صورة هذه الصفحة واستخرج كل النص العربي والإنجليزي والأرقام حرفياً ومباشرة بالترتيب من اليمين لليسار ومن أعلى لأسفل، "
                "دون أي مقدمة أو تعليق أو تلخيص أو عناوين مضافة. حافظ على الجداول والأرقام وعناوين المواد والأبواب بدقة."
            )
        ocr_raw = _call_local_ollama_vision(buf.getvalue(), prompt, num_ctx=3072, num_predict=1150)
        ocr_clean = _clean_ocr_output(ocr_raw)
        has_bad = any(_is_mojibake_char(c) for c in ocr_clean)
        if has_bad and use_raw_draft:
            # Model echoed damaged draft glyphs; retry cleanly from higher-DPI image + numeric hints only
            continue
        if has_bad:
            ocr_clean = "".join(c for c in ocr_clean if not _is_mojibake_char(c))
        if len(ocr_clean.strip()) >= 15 or dark <= 0.01:
            return ocr_clean.strip()
    return ""


def _extract_pypdf_pages_coords(file_content: bytes) -> tuple[list[str], float, float]:
    """Coordinate-aware PDF text reconstruction supporting RTL Arabic lines and Y-baseline jitter."""
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


def _deduplicate_pdf_headers_footers(pages: list[str]) -> list[str]:
    """Remove boilerplate single-line headers/footers repeated across pages while keeping Page 1 copy."""
    import math
    from collections import Counter

    if len(pages) < 3:
        return pages
    thresh = max(3, math.ceil(len(pages) * 0.45))
    first_lines: Counter[str] = Counter()
    second_lines: Counter[str] = Counter()
    last_lines: Counter[str] = Counter()
    split_pages = [p.splitlines() for p in pages]
    for lns in split_pages:
        ne = [ln.strip() for ln in lns if ln.strip()]
        if ne:
            first_lines[ne[0]] += 1
            if len(ne) > 1:
                second_lines[ne[1]] += 1
            last_lines[ne[-1]] += 1

    heading_pat = re.compile(r"^(?:\\d+|البند|الباب|المادة|الفصل|Clause|Section|Article)\\b")
    rep_top = {
        k for k, v in (first_lines + second_lines).items()
        if v >= thresh and len(k) < 110 and not heading_pat.match(k)
    }
    rep_bot = {
        k for k, v in last_lines.items()
        if v >= thresh and len(k) < 110 and not heading_pat.match(k)
    }
    # Also strip bare repeated 'صفحة N' / 'Page N' footers on >= 4-page docs while relying on [صفحة X من N]
    page_num_re = re.compile(r"^(?:صفحة|Page)\\s+\\d+(?:\\s*(?:من|of|/)\\s*\\d+)?$", re.IGNORECASE)

    cleaned: list[str] = []
    seen_top: set[str] = set()
    seen_bot: set[str] = set()
    for pno, lns in enumerate(split_pages, 1):
        out_lns: list[str] = []
        ne_indices = [idx for idx, ln in enumerate(lns) if ln.strip()]
        top_set = set(ne_indices[:2])
        last_idx = ne_indices[-1] if ne_indices else -1
        for idx, ln in enumerate(lns):
            s = ln.strip()
            if pno > 1 and page_num_re.match(s) and len(pages) >= 4:
                continue
            if idx in top_set and s in rep_top:
                if s in seen_top:
                    continue
                seen_top.add(s)
            elif idx == last_idx and s in rep_bot:
                if s in seen_bot:
                    continue
                seen_bot.add(s)
            out_lns.append(ln)
        txt = "\\n".join(out_lns)
        # Collapse excessive dotted form lines so forms keep structure without burning context tokens
        txt = re.sub(r"[.\\u2026]{6,}", " ______ ", txt)
        txt = re.sub(r"_{7,}", " ______ ", txt)
        cleaned.append(txt.strip())
    return cleaned


def _split_long_doc_chunks(body: str, target_chars: int = 16500, max_chunks: int = 14) -> list[tuple[str, str]]:
    """Split oversized documents along page or paragraph boundaries for staged Map-Reduce."""
    page_blocks = re.split(r"(?=^---\\s*\\[صفحة\\s+\\d+)", body, flags=re.MULTILINE)
    if len(page_blocks) > 1:
        units = [u.strip() for u in page_blocks if u.strip()]
    else:
        units = [u.strip() for u in re.split(r"\\n{2,}", body) if u.strip()]

    chunks: list[tuple[str, str]] = []
    cur: list[str] = []
    cur_len = 0
    for u in units:
        if cur and cur_len + len(u) > target_chars and len(chunks) < max_chunks - 1:
            joined = "\\n\\n".join(cur)
            pnums = re.findall(r"\\[صفحة\\s+(\\d+)\\s+من\\s+(\\d+)\\]", joined)
            lbl = f"صفحات {pnums[0][0]}–{pnums[-1][0]}" if pnums else f"الجزء {len(chunks) + 1}"
            chunks.append((lbl, joined))
            cur = [u]
            cur_len = len(u)
        else:
            cur.append(u)
            cur_len += len(u) + 2
    if cur:
        joined = "\\n\\n".join(cur)
        pnums = re.findall(r"\\[صفحة\\s+(\\d+)\\s+من\\s+(\\d+)\\]", joined)
        lbl = f"صفحات {pnums[0][0]}–{pnums[-1][0]}" if pnums else f"الجزء {len(chunks) + 1}"
        chunks.append((lbl, joined))
    return chunks


def _extract_chunk_headings(chunk_text: str, limit: int = 24) -> str:
    """Preserve exact Clause/Section/Article titles & numbers from each oversized chunk."""
    pat = re.compile(
        r"^(?:\\d{1,2}(?:\\.\\d+)?\\s+[A-Z\\u0600-\\u06FF][^\\n]{2,75}|"
        r"(?:Clause|Section|Article|SCHEDULE|المادة|الباب|البند)\\s*[\\(\\[]?\\d+[\\)\\]]?[^\\n]{0,75})$",
        re.MULTILINE,
    )
    seen: set[str] = set()
    heads: list[str] = []
    for m in pat.finditer(chunk_text):
        h = re.sub(r"\\s+", " ", m.group(0)).strip()
        if h and h not in seen:
            seen.add(h)
            heads.append(h)
            if len(heads) >= limit:
                break
    return " | ".join(heads)


def _build_staged_long_document_digest(text: str, *, max_tokens_budget: int = 15000) -> str:
    """Summarize oversized documents chunk-by-chunk across ALL pages so no middle/tail clauses vanish."""
    import hashlib

    h = hashlib.sha256(f"mr132|{max_tokens_budget}|{text}".encode("utf-8", errors="ignore")).hexdigest()
    cached = _cache_read(f"{h}.mr132")
    if cached and cached.get("digest"):
        return str(cached["digest"])

    header = ""
    body = text
    m_hdr = re.match(r"^(\\[اسم الملف المرفق:[^\\]]+\\]\\s*\\n(?:\\[بيانات الترويسة[^\\]]+\\]\\s*\\n)?)", text)
    if m_hdr:
        header = m_hdr.group(1)
        body = text[len(header):]

    chunks = _split_long_doc_chunks(body, target_chars=16000, max_chunks=14)
    digests: list[str] = []
    map_failed = False
    for idx, (lbl, ch_txt) in enumerate(chunks, 1):
        try:
            headings = _extract_chunk_headings(ch_txt)
            prompt = (
                f"أنت مستخرج بيانات تعاقدية دقيق. لخّص الجزء {idx} من {len(chunks)} ({lbl}) باللغة الأصلية للمقطع "
                "وبنقاط مركزة جداً دون مقدمات، مع الحفاظ الإلزامي والحرفي على: كل أرقام البنود/المواد (مثل Clause 1 أو Clause 31 أو المادة 15) وعناوينها، أسماء الأطراف، "
                "الأرقام والنسب والمدد والغرامات وحدود المسؤولية، الشروط والاستثناءات وأدوات النفي (لا/لم/يمنع/دون إخلال)، وأحكام الإنهاء:\\n\\n"
                f"{ch_txt[:18000]}"
            )
            summary = _call_local_ollama_chat(
                [{"role": "user", "content": prompt}],
                num_ctx=8192,
                num_predict=650,
                timeout=120,
            )
            if summary:
                idx_line = f"[عناوين وبنود الجزء الحرفية: {headings}]\\n" if headings else ""
                digests.append(f"=== [خلاصة الجزء {idx} من {len(chunks)} — {lbl}] ===\\n{idx_line}{summary}")
        except Exception:
            logger.warning("Staged digest failed on chunk %d/%d", idx, len(chunks), exc_info=True)
            map_failed = True
            break

    opening_excerpt = body[:3600].strip()
    if digests and not map_failed:
        banner = (
            "[تنبيه معالجة مرحلية لمستند طويل / STAGED FULL-DOCUMENT DIGEST]\\n"
            f"إجمالي طول المستند المستخرج: {len(text):,} حرفاً ({len(chunks)} أجزاء تمت قراءتها وتلخيصها تباعاً عبر المعالج المحلي من البداية إلى النهاية).\\n"
            "يعرض هذا القسم خلاصة منظمة وشاملة لكل أجزاء المستند (1.."
            f"{len(chunks)}) مع الفهارس الحرفية لأرقام البنود والمقتطف الافتتاحي، لتجنب بتر منتصف المستند أو نهايته.\\n"
            "[/تنبيه معالجة مرحلية لمستند طويل]\\n\\n"
        )
        result = f"{header}{banner}[مقتطف افتتاحي حرفي]\\n{opening_excerpt}\\n\\n" + "\\n\\n".join(digests)
        if _estimate_qwen_tokens(result) > max_tokens_budget:
            # Trim opening excerpt first so all staged section summaries remain intact
            result = f"{header}{banner}" + "\\n\\n".join(digests)
        _cache_write(f"{h}.mr132", {"digest": result, "chunks": len(chunks)})
        return result

    # Fallback ONLY if Ollama endpoint was unreachable during Map-Reduce
    head_cut = min(len(body), 16000)
    tail_cut = min(len(body) - head_cut, 10000) if len(body) > head_cut else 0
    banner = (
        "[⚠️ تنبيه حد النافذة المحلية / LOCAL CONTEXT WINDOW LIMIT EXCEEDED]\\n"
        f"إجمالي طول النص المستخرج: {len(text):,} حرفاً، وتعذر إكمال التلخيص المرحلي التلقائي.\\n"
        f"يعرض النظام الجزء الافتتاحي ({head_cut:,} حرفاً) والمقطع الختامي ({tail_cut:,} حرفاً). أفصح للمستخدم بصدق عن الجزء الوسيط غير الظاهر.\\n"
        "[/تنبيه حد النافذة المحلية]\\n\\n"
    )
    tail_block = f"\\n\\n--- [المقطع الختامي للمستند] ---\\n{body[-tail_cut:]}" if tail_cut > 0 else ""
    return f"{header}{banner}{body[:head_cut]}{tail_block}"


def _apply_local_window_guard(text: str, *, max_tokens_budget: int = 15000) -> str:
    """Keep extracted document inside local LLM context; run Map-Reduce digest if oversized."""
    if _estimate_qwen_tokens(text) <= max_tokens_budget:
        return text
    return _build_staged_long_document_digest(text, max_tokens_budget=max_tokens_budget)


def _make_extraction_unavailable_msg(filename: str, reason: str = "تعذر قراءة أو استخراج محتوى نصي من الملف") -> str:
    """Structured sentinel so empty/unreadable uploads NEVER trigger false 'no file uploaded' replies."""
    return (
        "[EXTRACTION_UNAVAILABLE]\\n"
        f"اسم الملف المرفق: {filename}\\n"
        f"الحالة: تم استلام ملفك بنجاح، لكن تعذر استخراج النص منه ({reason}).\\n"
        "التعليمات الإلزامية للنموذج: أجب المستخدم نصياً بأن ملفه تم استلامه بنجاح لكن تعذر استخراج النص منه "
        "(«تم استلام ملفك بنجاح، لكن تعذر استخراج النص منه.»)، ووضح أن السبب قد يكون خلو الملف من النص أو مسحه بجودة منخفضة أو تشفيره، واقترح تزويدك بنسخة نصية أوضح. لا تدّعِ أبداً عدم رفع مرفق.\\n"
        "[/EXTRACTION_UNAVAILABLE]"
    )


def _safe_extract_with_guard(
    http_client: HttpClientProtocol,
    file: File,
    *,
    unstructured_api_config: UnstructuredApiConfig,
    max_tokens_budget: int = 15000,
) -> str:
    """Extract and guard one uploaded file without losing empty-file or broken-file attribution."""
    fname = file.filename or "document"
    try:
        raw = _extract_text_from_file(
            http_client,
            file,
            unstructured_api_config=unstructured_api_config,
        )
    except Exception as exc:
        logger.warning("Extraction error on %s: %s", fname, exc, exc_info=True)
        return _make_extraction_unavailable_msg(fname, str(exc))

    meaningful = re.sub(r"---\\s*\\[صفحة\\s+\\d+\\s+من\\s+\\d+\\]\\s*---|\\s+", "", raw or "")
    if len(meaningful) < 15:
        return _make_extraction_unavailable_msg(fname, "المحتوى المستخرج فارغ أو غير مقروء حتى بعد المسح البصري المحلي")

    tagged = f"[اسم الملف المرفق: {fname}]\\n{raw}"
    return _apply_local_window_guard(tagged, max_tokens_budget=max_tokens_budget)


def _extract_text_from_pdf(file_content: bytes) -> str:
    """Universal local PDF extractor handling clean digital, RTL torn-ligature, broken ToUnicode CMap, and scanned PDFs."""
    import hashlib
    import unicodedata

    file_hash = hashlib.sha256(file_content).hexdigest()
    cached = _cache_read(f"{file_hash}.v132")
    if cached and isinstance(cached.get("text"), str) and cached["text"].strip():
        return cached["text"]

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
    used_full_ocr = False
    ocr_doc = None
    try:
        for idx in range(num_pages):
            p_raw = pdfium_pages[idx] if idx < len(pdfium_pages) else ""
            c_raw = pypdf_pages[idx] if idx < len(pypdf_pages) else ""
            broken_pdfium = _has_broken_cmap(p_raw)
            broken_pypdf = _has_broken_cmap(c_raw)
            torn_pdfium = _count_torn_arabic_lines(p_raw)
            torn_pypdf = _count_torn_arabic_lines(c_raw)

            page_txt = ""
            need_ocr = False
            if broken_pdfium and (broken_pypdf or len(c_raw.strip()) < 40):
                need_ocr = True
            elif not broken_pdfium and len(p_raw.strip()) >= 40 and (
                torn_pdfium <= 1 or (torn_pdfium <= torn_pypdf and (broken_pypdf or len(c_raw.strip()) < 40))
            ):
                page_txt = unicodedata.normalize("NFKC", p_raw).strip()
            elif not broken_pypdf and len(c_raw.strip()) >= 40:
                page_txt = c_raw.strip()
            elif not broken_pdfium and len(p_raw.strip()) > 0:
                page_txt = unicodedata.normalize("NFKC", p_raw).strip()

            if len(page_txt) < 40 or need_ocr:
                try:
                    with _PDFIUM_LOCK:
                        if ocr_doc is None:
                            ocr_doc = pypdfium2.PdfDocument(io.BytesIO(file_content), autoclose=True)
                        if idx < len(ocr_doc):
                            ocr_txt = _render_pdf_page_ocr(
                                ocr_doc,
                                idx,
                                unicodedata.normalize("NFKC", p_raw),
                                broken_cmap=need_ocr,
                            )
                            if ocr_txt:
                                page_txt = ocr_txt
                                used_full_ocr = True
                except Exception:
                    logger.debug("Local page Vision OCR failed on page %d", idx + 1, exc_info=True)

            chosen_pages.append(page_txt)
    finally:
        if ocr_doc is not None:
            try:
                ocr_doc.close()
            except Exception:
                pass

    chosen_pages = _deduplicate_pdf_headers_footers(chosen_pages)

    # Check Page 1 header/footer graphics missing from text stream ONLY when full-page OCR wasn't already run on Page 1
    banner_meta = ""
    if not used_full_ocr and (p1_top_empty >= 0.11 or p1_bot_empty >= 0.08) and len(chosen_pages) >= 1 and chosen_pages[0]:
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
                    banner.save(bbuf, format="JPEG", quality=88)
                    vis_hdr = _call_local_ollama_vision(
                        bbuf.getvalue(),
                        "انظر إلى صورة ترويسة وتذييل الصفحة الأولى فقط. استخرج بدقة اسم الشركة أو الجهة بالعربية (بشكل سليم من اليمين لليسار) والإنجليزية، وعنوان الوثيقة والموقع الإلكتروني إن ظهرت بصرياً دون تخمين.",
                        num_ctx=2048,
                        num_predict=350,
                    )
                    if vis_hdr:
                        banner_meta = (
                            "[بيانات الترويسة وهوية المستند المستخلصة بصرياً (Metadata من الصفحة 1):\\n"
                            f"{vis_hdr}\\n]\\n\\n"
                        )
        except Exception:
            logger.debug("Page 1 visual letterhead check failed", exc_info=True)

    non_empty_pages = [p for p in chosen_pages if p.strip()]
    if not non_empty_pages:
        return ""

    formatted_pages = [
        f"--- [صفحة {i} من {num_pages}] ---\\n{pt}" if num_pages > 1 else pt
        for i, pt in enumerate(chosen_pages, 1)
    ]
    final_text = banner_meta + "\\n\\n".join(formatted_pages)
    if final_text.strip():
        _cache_write(f"{file_hash}.v132", {"num_pages": num_pages, "used_vision": used_full_ocr, "text": final_text})
    return final_text
'''


def build_patched_source(src: str) -> str:
    """Apply idempotent v1.3.1 universal extractor transformations to pristine Dify v1.18.0 node.py source."""
    for req_import in ("import os", "import re"):
        if req_import not in src:
            src = src.replace("import json\n", f"import json\n{req_import}\n", 1)

    old_list_call = '''        if isinstance(value, list):
            try:
                extracted_text_list = [
                    _extract_text_from_file(
                        self._http_client,
                        file,
                        unstructured_api_config=self._unstructured_api_config,
                    )
                    for file in value
                ]
            except DocumentExtractorError as e:
                logger.warning(e, exc_info=True)
                return NodeRunResult(
                    status=WorkflowNodeExecutionStatus.FAILED,
                    error=str(e),
                    inputs=inputs,
                    process_data=process_data,
                )
            outputs = {"text": ArrayStringSegment(value=extracted_text_list)}'''

    new_list_call = '''        if isinstance(value, list):
            per_budget = 15000 if len(value) <= 1 else max(4500, 15000 // len(value))
            extracted_text_list = [
                _safe_extract_with_guard(
                    self._http_client,
                    file,
                    unstructured_api_config=self._unstructured_api_config,
                    max_tokens_budget=per_budget,
                )
                for file in value
            ]
            outputs = {"text": ArrayStringSegment(value=extracted_text_list)}'''

    assert old_list_call in src, "old_list_call block not found in baseline node.py"
    src = src.replace(old_list_call, new_list_call, 1)

    old_single_call = '''        else:
            try:
                extracted_text = _extract_text_from_file(
                    self._http_client,
                    value,
                    unstructured_api_config=self._unstructured_api_config,
                )
            except DocumentExtractorError as e:
                logger.warning(e, exc_info=True)
                return NodeRunResult(
                    status=WorkflowNodeExecutionStatus.FAILED,
                    error=str(e),
                    inputs=inputs,
                    process_data=process_data,
                )
            outputs = {"text": extracted_text}'''

    new_single_call = '''        else:
            extracted_text = _safe_extract_with_guard(
                self._http_client,
                value,
                unstructured_api_config=self._unstructured_api_config,
                max_tokens_budget=15000,
            )
            outputs = {"text": extracted_text}'''

    assert old_single_call in src, "old_single_call block not found in baseline node.py"
    src = src.replace(old_single_call, new_single_call, 1)

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

    assert old_pdf_fn in src, "old_pdf_fn block not found in baseline node.py"
    src = src.replace(old_pdf_fn, HELPER_MODULE.strip(), 1)
    return src


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", help="Path to clean baseline v1.18.0 node.py")
    parser.add_argument("--output", help="Path to write canonical patched node.py")
    args = parser.parse_args()

    if args.source and args.output:
        with open(args.source, "r", encoding="utf-8") as f:
            baseline = f.read().replace("\r\n", "\n")
        patched = build_patched_source(baseline).replace("\r\n", "\n")
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(patched)
        print(f"Generated canonical patched node.py -> {args.output} ({len(patched)} bytes)")
        return

    backup = DEFAULT_TARGET + ".orig_v1_18"
    if not os.path.exists(backup):
        shutil.copy2(DEFAULT_TARGET, backup)
        print(f"Backed up original node.py -> {backup}")
    with open(backup, "r", encoding="utf-8") as f:
        baseline = f.read().replace("\r\n", "\n")
    patched = build_patched_source(baseline).replace("\r\n", "\n")
    with open(DEFAULT_TARGET, "w", encoding="utf-8", newline="\n") as f:
        f.write(patched)
    print(f"Successfully patched {DEFAULT_TARGET} ({len(patched)} bytes)")


if __name__ == "__main__":
    main()

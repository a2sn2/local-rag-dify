from __future__ import annotations

import csv
import io
import json
import re
import os
import logging
import pathlib
import posixpath
import tempfile
import threading
import zipfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, override
from urllib.parse import unquote, urlsplit

import charset_normalizer
import docx
import pandas as pd
import pypdf
import pypdfium2
import webvtt
import yaml
from defusedxml import ElementTree
from docx.document import Document
from docx.oxml.table import CT_Tbl
from docx.oxml.text.paragraph import CT_P
from docx.table import Table
from docx.text.paragraph import Paragraph
from odfdo import Document as OdfDocument

from graphon.enums import BuiltinNodeTypes, WorkflowNodeExecutionStatus
from graphon.file import file_manager
from graphon.file.enums import FileTransferMethod
from graphon.file.models import File
from graphon.http import HttpClientProtocol, HttpxHttpClient
from graphon.node_events.base import NodeRunResult
from graphon.nodes.base.node import Node
from graphon.runtime.init_params import InitParams
from graphon.runtime.runtime_state import RuntimeState
from graphon.variables.segments import ArrayFileSegment, ArrayStringSegment, FileSegment

from .entities import DocumentExtractorNodeData, UnstructuredApiConfig
from .exc import (
    DocumentExtractorError,
    FileDownloadError,
    TextExtractionError,
    UnsupportedFileTypeError,
)

logger = logging.getLogger(__name__)
_PDFIUM_LOCK = threading.Lock()
_UNSTRUCTURED_PARTITION_ENDPOINT = "/general/v0/general"

_MIME_PLAIN_TEXT_TYPES = frozenset((
    "text/plain",
    "text/html",
    "text/htm",
    "text/markdown",
    "text/xml",
))
_EXTENSION_PLAIN_TEXT_TYPES = frozenset((
    ".txt",
    ".markdown",
    ".md",
    ".mdx",
    ".html",
    ".htm",
    ".xml",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
    ".cc",
    ".cxx",
    ".c++",
    ".py",
    ".js",
    ".ts",
    ".jsx",
    ".tsx",
    ".java",
    ".php",
    ".rb",
    ".go",
    ".rs",
    ".swift",
    ".kt",
    ".scala",
    ".sh",
    ".bash",
    ".bat",
    ".ps1",
    ".sql",
    ".r",
    ".m",
    ".pl",
    ".lua",
    ".vim",
    ".asm",
    ".s",
    ".css",
    ".scss",
    ".less",
    ".sass",
    ".ini",
    ".cfg",
    ".conf",
    ".toml",
    ".env",
    ".log",
    ".vtt",
))


@dataclass(frozen=True)
class _ExtractorRegistration:
    name: str
    extractor: Callable[..., str]
    mime_types: frozenset[str] = frozenset()
    file_extensions: frozenset[str] = frozenset()
    requires_unstructured_config: bool = False

    def extract(
        self,
        *,
        file_content: bytes,
        unstructured_api_config: UnstructuredApiConfig,
    ) -> str:
        if self.requires_unstructured_config:
            return self.extractor(
                file_content,
                unstructured_api_config=unstructured_api_config,
            )
        return self.extractor(file_content)


class _TextExtractorRegistry:
    def __init__(self, registrations: Sequence[_ExtractorRegistration]) -> None:
        self._mime_type_extractors = self._build_lookup(
            registrations,
            kind_selector=lambda registration: registration.mime_types,
        )
        self._file_extension_extractors = self._build_lookup(
            registrations,
            kind_selector=lambda registration: registration.file_extensions,
        )

    def extract_by_mime_type(
        self,
        *,
        file_content: bytes,
        mime_type: str,
        unstructured_api_config: UnstructuredApiConfig,
    ) -> str:
        return self._extract(
            extractor_lookup=self._mime_type_extractors,
            file_content=file_content,
            file_kind=mime_type,
            unstructured_api_config=unstructured_api_config,
            error_label="Unsupported MIME type",
        )

    def extract_by_file_extension(
        self,
        *,
        file_content: bytes,
        file_extension: str,
        unstructured_api_config: UnstructuredApiConfig,
    ) -> str:
        return self._extract(
            extractor_lookup=self._file_extension_extractors,
            file_content=file_content,
            file_kind=file_extension,
            unstructured_api_config=unstructured_api_config,
            error_label="Unsupported Extension Type",
        )

    @staticmethod
    def _build_lookup(
        registrations: Sequence[_ExtractorRegistration],
        *,
        kind_selector: Callable[[_ExtractorRegistration], frozenset[str]],
    ) -> dict[str, _ExtractorRegistration]:
        lookup: dict[str, _ExtractorRegistration] = {}
        for registration in registrations:
            for kind in kind_selector(registration):
                if kind in lookup:
                    current_registration = lookup[kind]
                    msg = (
                        f"Duplicate extractor registration for {kind!r}: "
                        f"{current_registration.name} and {registration.name}"
                    )
                    raise ValueError(msg)
                lookup[kind] = registration
        return lookup

    @staticmethod
    def _extract(
        *,
        extractor_lookup: Mapping[str, _ExtractorRegistration],
        file_content: bytes,
        file_kind: str,
        unstructured_api_config: UnstructuredApiConfig,
        error_label: str,
    ) -> str:
        registration = extractor_lookup.get(file_kind)
        if registration is None:
            msg = f"{error_label}: {file_kind}"
            raise UnsupportedFileTypeError(msg)
        return registration.extract(
            file_content=file_content,
            unstructured_api_config=unstructured_api_config,
        )


def _to_unstructured_server_url(api_url: str | None) -> str | None:
    return (
        api_url.removesuffix(_UNSTRUCTURED_PARTITION_ENDPOINT) if api_url else api_url
    )


def _to_unstructured_timeout_ms(timeout_seconds: float) -> int:
    return int(timeout_seconds * 1000)


def _partition_file_via_unstructured_api(
    file_content: bytes,
    *,
    suffix: str,
    unstructured_api_config: UnstructuredApiConfig,
) -> Sequence[Any]:
    from unstructured.staging.base import (  # ruff:ignore[import-outside-top-level]
        elements_from_dicts,
    )
    from unstructured_client import (  # ruff:ignore[import-outside-top-level]
        UnstructuredClient,
    )
    from unstructured_client.models import (  # ruff:ignore[import-outside-top-level]
        operations,
        shared,
    )

    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as temp_file:
        temp_file.write(file_content)
        temp_file.flush()
        temp_path = pathlib.Path(temp_file.name)

    try:
        with temp_path.open("rb") as file:
            files = shared.Files(content=file, file_name=temp_path.name)
            request = operations.PartitionRequest(
                partition_parameters=shared.PartitionParameters(files=files),
            )
            with UnstructuredClient(
                api_key_auth=unstructured_api_config.api_key or "",
                server_url=_to_unstructured_server_url(
                    unstructured_api_config.api_url,
                ),
            ) as client:
                response = client.general.partition(
                    request=request,
                    retries=None,
                    timeout_ms=_to_unstructured_timeout_ms(
                        unstructured_api_config.timeout_seconds,
                    ),
                )
            return elements_from_dicts(response.elements or [])
    finally:
        temp_path.unlink(missing_ok=True)


class DocumentExtractorNode(Node[DocumentExtractorNodeData]):
    """Extracts text content from various file types.
    Supports plain text, PDF, and DOC/DOCX files.
    """

    node_type = BuiltinNodeTypes.DOCUMENT_EXTRACTOR

    @classmethod
    @override
    def version(cls) -> str:
        return "1"

    @override
    def __init__(
        self,
        node_id: str,
        data: DocumentExtractorNodeData,
        *,
        init_params: InitParams,
        runtime_state: RuntimeState,
        unstructured_api_config: UnstructuredApiConfig | None = None,
        http_client: HttpClientProtocol | None = None,
    ) -> None:
        super().__init__(
            node_id=node_id,
            data=data,
            init_params=init_params,
            runtime_state=runtime_state,
        )
        self._unstructured_api_config = (
            unstructured_api_config or UnstructuredApiConfig()
        )
        self._http_client = (
            http_client if http_client is not None else HttpxHttpClient()
        )

    @property
    def http_client(self) -> HttpClientProtocol:
        """Return the HTTP client used to retrieve file contents."""
        return self._http_client

    @override
    def _run(self) -> NodeRunResult:
        variable_selector = self.node_data.variable_selector
        variable = self.runtime_state.variable_pool.get(variable_selector)

        error_message = None
        if variable is None:
            error_message = f"File variable not found for selector: {variable_selector}"
        elif variable.value and not isinstance(
            variable,
            ArrayFileSegment | FileSegment,
        ):
            error_message = f"Variable {variable_selector} is not an ArrayFileSegment"

        if error_message is not None:
            return NodeRunResult(
                status=WorkflowNodeExecutionStatus.FAILED,
                error=error_message,
            )

        if variable is None:
            msg = f"File variable not found for selector: {variable_selector}"
            return NodeRunResult(
                status=WorkflowNodeExecutionStatus.FAILED,
                error=msg,
            )
        value = variable.value
        inputs = {"variable_selector": variable_selector}
        if isinstance(value, list):
            value = list(filter(lambda x: x, value))
        process_data = {"documents": value if isinstance(value, list) else [value]}

        if not value:
            return NodeRunResult(
                status=WorkflowNodeExecutionStatus.SUCCEEDED,
                inputs=inputs,
                process_data=process_data,
                outputs={"text": ArrayStringSegment(value=[])},
            )

        if isinstance(value, list):
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
            outputs = {"text": ArrayStringSegment(value=extracted_text_list)}
        else:
            extracted_text = _safe_extract_with_guard(
                self._http_client,
                value,
                unstructured_api_config=self._unstructured_api_config,
                max_tokens_budget=15000,
            )
            outputs = {"text": extracted_text}

        return NodeRunResult(
            status=WorkflowNodeExecutionStatus.SUCCEEDED,
            inputs=inputs,
            process_data=process_data,
            outputs=outputs,
        )

    @classmethod
    @override
    def _extract_variable_selector_to_variable_mapping(
        cls,
        *,
        graph_config: Mapping[str, Any],
        node_id: str,
        node_data: DocumentExtractorNodeData,
    ) -> Mapping[str, Sequence[str]]:
        _ = graph_config  # Explicitly mark as unused
        return {node_id + ".files": node_data.variable_selector}


def _extract_text_by_mime_type(
    *,
    file_content: bytes,
    mime_type: str,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    """Extract text from a file based on its MIME type."""
    return _TEXT_EXTRACTOR_REGISTRY.extract_by_mime_type(
        file_content=file_content,
        mime_type=mime_type,
        unstructured_api_config=unstructured_api_config,
    )


def _extract_text_by_file_extension(
    *,
    file_content: bytes,
    file_extension: str,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    """Extract text from a file based on its file extension."""
    return _TEXT_EXTRACTOR_REGISTRY.extract_by_file_extension(
        file_content=file_content,
        file_extension=file_extension,
        unstructured_api_config=unstructured_api_config,
    )


def _extract_text_from_plain_text(file_content: bytes) -> str:
    try:
        # Detect encoding using charset_normalizer
        result = charset_normalizer.from_bytes(
            file_content,
            cp_isolation=["utf_8", "latin_1", "cp1252"],
        ).best()
        encoding = result.encoding if result else "utf-8"

        # Fallback to utf-8 if detection fails
        if not encoding:
            encoding = "utf-8"

        return file_content.decode(encoding, errors="ignore")
    except (UnicodeDecodeError, LookupError) as e:
        # If decoding fails, try with utf-8 as last resort
        try:
            return file_content.decode("utf-8", errors="ignore")
        except UnicodeDecodeError:
            msg = f"Failed to decode plain text file: {e}"
            raise TextExtractionError(msg) from e


def _extract_text_from_json(file_content: bytes) -> str:
    try:
        # Detect encoding using charset_normalizer
        result = charset_normalizer.from_bytes(file_content).best()
        encoding = result.encoding if result else "utf-8"

        # Fallback to utf-8 if detection fails
        if not encoding:
            encoding = "utf-8"

        json_data = json.loads(file_content.decode(encoding, errors="ignore"))
        return json.dumps(json_data, indent=2, ensure_ascii=False)
    except (UnicodeDecodeError, LookupError, json.JSONDecodeError) as e:
        # If decoding fails, try with utf-8 as last resort
        try:
            json_data = json.loads(file_content.decode("utf-8", errors="ignore"))
            return json.dumps(json_data, indent=2, ensure_ascii=False)
        except (UnicodeDecodeError, json.JSONDecodeError):
            msg = f"Failed to decode or parse JSON file: {e}"
            raise TextExtractionError(msg) from e


def _extract_text_from_yaml(file_content: bytes) -> str:
    """Extract the content from yaml file"""
    try:
        # Detect encoding using charset_normalizer
        result = charset_normalizer.from_bytes(file_content).best()
        encoding = result.encoding if result else "utf-8"

        # Fallback to utf-8 if detection fails
        if not encoding:
            encoding = "utf-8"

        yaml_data = yaml.safe_load_all(file_content.decode(encoding, errors="ignore"))
        return yaml.dump_all(yaml_data, allow_unicode=True, sort_keys=False)
    except (UnicodeDecodeError, LookupError, yaml.YAMLError) as e:
        # If decoding fails, try with utf-8 as last resort
        try:
            yaml_data = yaml.safe_load_all(
                file_content.decode("utf-8", errors="ignore"),
            )
            return yaml.dump_all(yaml_data, allow_unicode=True, sort_keys=False)
        except (UnicodeDecodeError, yaml.YAMLError):
            msg = f"Failed to decode or parse YAML file: {e}"
            raise TextExtractionError(msg) from e


_DOC_CACHE_DIR = os.environ.get("BASEERA_DOC_CACHE_DIR", "/app/api/storage/doc_cache")
_OCR_BOILERPLATE_RE = re.compile(
    r"^(?:إليك\s+النص[^:\n]*:|بناءً\s+على\s+الصورة[^:\n]*:|"
    r"\*{0,2}النص\s+(?:العربي|الإنجليزي|المستخرج)[^\n]*\*{0,2}\s*:?|"
    r"\*{0,2}الأرقام[^\n]*\*{0,2}\s*:?|بالترتيب\s+من\s+أعلى[^\n]*:?)$",
    re.MULTILINE,
)


def _count_torn_arabic_lines(text: str) -> int:
    """Count fragmented 1-3 char Arabic lines caused by PDFium ligature splits."""
    bad = 0
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            continue
        if len(s) <= 3 and any("\u0600" <= c <= "\u06FF" or "\uFE70" <= c <= "\uFEFF" for c in s):
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
        r"(?<![\u0621-\u064A])([بتثجحخدذرزسشصضطظعغفقكلمنهي])\s+(ي|ى|ن|ح|خ|ت|ة|م|ر|ل|ز|ك|هـ?|ا)(?![\u0621-\u064A])",
        r"\1\2",
        text,
    )
    text = re.sub(
        r"([\u0621-\u064A]{2,}[\u064B-\u065F]*)\s+([يتنحخزرصضطظعغفقكلمههةى])(?=\s|[،؛.:\n\)\]]|$)",
        r"\1\2",
        text,
    )
    text = re.sub(r"([\u0621-\u064A])\s+([\u064B-\u065F]+ا?)(?=\s|[،؛.:\n\)\]]|$)", r"\1\2", text)
    text = re.sub(r"(?<![\u0621-\u064A])(ال)\s+([\u0621-\u064A]{2,})", r"\1\2", text)
    return text


def _estimate_qwen_tokens(text: str) -> int:
    """Estimate qwen3.5:4b token count accurately without over-penalizing clean Arabic."""
    if not text:
        return 0
    acc = 0.0
    for ch in text:
        if "\u0600" <= ch <= "\u06FF" or "\uFE70" <= ch <= "\uFEFF":
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
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
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
    tokens = re.findall(r"(?:www\.[A-Za-z0-9._-]+|[A-Za-z0-9\u0660-\u0669٪%.,:/()\-]{2,}|[\u0660-\u0669\d]+)", raw_txt or "")
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
                "دون أي مقدمة أو تعليق أو عناوين مثل 'إليك النص' أو 'النص العربي' أو 'الأرقام'.\n"
                "ملاحظة: النص الأولي أدناه مأخوذ من نفس الصفحة وبه بعض الرموز التالفة؛ اعتمد على الصورة لقراءة الكلمات العربية "
                "وأدوات النفي (لا / لم / لن / يمنع / يغلق) والجداول بدقة، واستعن بالأرقام الواضحة والأسماء السليمة في النص الأولي عند تطابقها مع الصورة:\n"
                f"{raw_hint}"
            )
        elif safe_hints:
            prompt = (
                "اقرأ صورة هذه الصفحة واستخرج كل النص العربي والإنجليزي والأرقام حرفياً ومباشرة بالترتيب من اليمين لليسار ومن أعلى لأسفل، "
                "دون أي مقدمة أو تعليق أو تلخيص أو عناوين مضافة. حافظ على الجداول وأدوات النفي وعناوين المواد والأبواب بدقة.\n"
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
                t_clean = text.replace("\r", "")
                if not t_clean.strip():
                    return
                x = cm[0] * tm[4] + cm[2] * tm[5] + cm[4]
                y = cm[1] * tm[4] + cm[3] * tm[5] + cm[5]
                fs = float(font_size or 11.0)
                fragments.append((y, x, fs, t_clean.strip("\n")))

            raw_probe = page.extract_text() or ""
            has_arabic = any("\u0600" <= ch <= "\u06FF" or "\uFE70" <= ch <= "\uFEFF" for ch in raw_probe)
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
                ar_cnt = sum(1 for c in line_all if "\u0600" <= c <= "\u06FF" or "\uFE70" <= c <= "\uFEFF")
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
                line = re.sub(r"\s{2,}", " ", line).strip()
                line = re.sub(r"^(\d+\s*[)\-\.])\s*:\s*(.+)$", r"\1 \2:", line)
                if line:
                    reconstructed_lines.append(_repair_arabic_kerning_spaces(line))
            pages_out.append("\n".join(reconstructed_lines))
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

    heading_pat = re.compile(r"^(?:\d+|البند|الباب|المادة|الفصل|Clause|Section|Article)\b")
    rep_top = {
        k for k, v in (first_lines + second_lines).items()
        if v >= thresh and len(k) < 110 and not heading_pat.match(k)
    }
    rep_bot = {
        k for k, v in last_lines.items()
        if v >= thresh and len(k) < 110 and not heading_pat.match(k)
    }
    # Also strip bare repeated 'صفحة N' / 'Page N' footers on >= 4-page docs while relying on [صفحة X من N]
    page_num_re = re.compile(r"^(?:صفحة|Page)\s+\d+(?:\s*(?:من|of|/)\s*\d+)?$", re.IGNORECASE)

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
        txt = "\n".join(out_lns)
        # Collapse excessive dotted form lines so forms keep structure without burning context tokens
        txt = re.sub(r"[.\u2026]{6,}", " ______ ", txt)
        txt = re.sub(r"_{7,}", " ______ ", txt)
        cleaned.append(txt.strip())
    return cleaned


def _split_long_doc_chunks(body: str, target_chars: int = 16500, max_chunks: int = 14) -> list[tuple[str, str]]:
    """Split oversized documents along page or paragraph boundaries for staged Map-Reduce."""
    page_blocks = re.split(r"(?=^---\s*\[صفحة\s+\d+)", body, flags=re.MULTILINE)
    if len(page_blocks) > 1:
        units = [u.strip() for u in page_blocks if u.strip()]
    else:
        units = [u.strip() for u in re.split(r"\n{2,}", body) if u.strip()]

    chunks: list[tuple[str, str]] = []
    cur: list[str] = []
    cur_len = 0
    for u in units:
        if cur and cur_len + len(u) > target_chars and len(chunks) < max_chunks - 1:
            joined = "\n\n".join(cur)
            pnums = re.findall(r"\[صفحة\s+(\d+)\s+من\s+(\d+)\]", joined)
            lbl = f"صفحات {pnums[0][0]}–{pnums[-1][0]}" if pnums else f"الجزء {len(chunks) + 1}"
            chunks.append((lbl, joined))
            cur = [u]
            cur_len = len(u)
        else:
            cur.append(u)
            cur_len += len(u) + 2
    if cur:
        joined = "\n\n".join(cur)
        pnums = re.findall(r"\[صفحة\s+(\d+)\s+من\s+(\d+)\]", joined)
        lbl = f"صفحات {pnums[0][0]}–{pnums[-1][0]}" if pnums else f"الجزء {len(chunks) + 1}"
        chunks.append((lbl, joined))
    return chunks


def _extract_chunk_headings(chunk_text: str, limit: int = 24) -> str:
    """Preserve exact Clause/Section/Article titles & numbers from each oversized chunk."""
    pat = re.compile(
        r"^(?:\d{1,2}(?:\.\d+)?\s+[A-Z\u0600-\u06FF][^\n]{2,75}|"
        r"(?:Clause|Section|Article|SCHEDULE|المادة|الباب|البند)\s*[\(\[]?\d+[\)\]]?[^\n]{0,75})$",
        re.MULTILINE,
    )
    seen: set[str] = set()
    heads: list[str] = []
    for m in pat.finditer(chunk_text):
        h = re.sub(r"\s+", " ", m.group(0)).strip()
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
    m_hdr = re.match(r"^(\[اسم الملف المرفق:[^\]]+\]\s*\n(?:\[بيانات الترويسة[^\]]+\]\s*\n)?)", text)
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
                "الأرقام والنسب والمدد والغرامات وحدود المسؤولية، الشروط والاستثناءات وأدوات النفي (لا/لم/يمنع/دون إخلال)، وأحكام الإنهاء:\n\n"
                f"{ch_txt[:18000]}"
            )
            summary = _call_local_ollama_chat(
                [{"role": "user", "content": prompt}],
                num_ctx=8192,
                num_predict=650,
                timeout=120,
            )
            if summary:
                idx_line = f"[عناوين وبنود الجزء الحرفية: {headings}]\n" if headings else ""
                digests.append(f"=== [خلاصة الجزء {idx} من {len(chunks)} — {lbl}] ===\n{idx_line}{summary}")
        except Exception:
            logger.warning("Staged digest failed on chunk %d/%d", idx, len(chunks), exc_info=True)
            map_failed = True
            break

    opening_excerpt = body[:3600].strip()
    if digests and not map_failed:
        banner = (
            "[تنبيه معالجة مرحلية لمستند طويل / STAGED FULL-DOCUMENT DIGEST]\n"
            f"إجمالي طول المستند المستخرج: {len(text):,} حرفاً ({len(chunks)} أجزاء تمت قراءتها وتلخيصها تباعاً عبر المعالج المحلي من البداية إلى النهاية).\n"
            "يعرض هذا القسم خلاصة منظمة وشاملة لكل أجزاء المستند (1.."
            f"{len(chunks)}) مع الفهارس الحرفية لأرقام البنود والمقتطف الافتتاحي، لتجنب بتر منتصف المستند أو نهايته.\n"
            "[/تنبيه معالجة مرحلية لمستند طويل]\n\n"
        )
        result = f"{header}{banner}[مقتطف افتتاحي حرفي]\n{opening_excerpt}\n\n" + "\n\n".join(digests)
        if _estimate_qwen_tokens(result) > max_tokens_budget:
            # Trim opening excerpt first so all staged section summaries remain intact
            result = f"{header}{banner}" + "\n\n".join(digests)
        _cache_write(f"{h}.mr132", {"digest": result, "chunks": len(chunks)})
        return result

    # Fallback ONLY if Ollama endpoint was unreachable during Map-Reduce
    head_cut = min(len(body), 16000)
    tail_cut = min(len(body) - head_cut, 10000) if len(body) > head_cut else 0
    banner = (
        "[⚠️ تنبيه حد النافذة المحلية / LOCAL CONTEXT WINDOW LIMIT EXCEEDED]\n"
        f"إجمالي طول النص المستخرج: {len(text):,} حرفاً، وتعذر إكمال التلخيص المرحلي التلقائي.\n"
        f"يعرض النظام الجزء الافتتاحي ({head_cut:,} حرفاً) والمقطع الختامي ({tail_cut:,} حرفاً). أفصح للمستخدم بصدق عن الجزء الوسيط غير الظاهر.\n"
        "[/تنبيه حد النافذة المحلية]\n\n"
    )
    tail_block = f"\n\n--- [المقطع الختامي للمستند] ---\n{body[-tail_cut:]}" if tail_cut > 0 else ""
    return f"{header}{banner}{body[:head_cut]}{tail_block}"


def _apply_local_window_guard(text: str, *, max_tokens_budget: int = 15000) -> str:
    """Keep extracted document inside local LLM context; run Map-Reduce digest if oversized."""
    if _estimate_qwen_tokens(text) <= max_tokens_budget:
        return text
    return _build_staged_long_document_digest(text, max_tokens_budget=max_tokens_budget)


def _make_extraction_unavailable_msg(filename: str, reason: str = "تعذر قراءة أو استخراج محتوى نصي من الملف") -> str:
    """Structured sentinel so empty/unreadable uploads NEVER trigger false 'no file uploaded' replies."""
    return (
        "[EXTRACTION_UNAVAILABLE]\n"
        f"اسم الملف المرفق: {filename}\n"
        f"الحالة: تم استلام ملفك بنجاح، لكن تعذر استخراج النص منه ({reason}).\n"
        "التعليمات الإلزامية للنموذج: أجب المستخدم نصياً بأن ملفه تم استلامه بنجاح لكن تعذر استخراج النص منه "
        "(«تم استلام ملفك بنجاح، لكن تعذر استخراج النص منه.»)، ووضح أن السبب قد يكون خلو الملف من النص أو مسحه بجودة منخفضة أو تشفيره، واقترح تزويدك بنسخة نصية أوضح. لا تدّعِ أبداً عدم رفع مرفق.\n"
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

    meaningful = re.sub(r"---\s*\[صفحة\s+\d+\s+من\s+\d+\]\s*---|\s+", "", raw or "")
    if len(meaningful) < 15:
        return _make_extraction_unavailable_msg(fname, "المحتوى المستخرج فارغ أو غير مقروء حتى بعد المسح البصري المحلي")

    tagged = f"[اسم الملف المرفق: {fname}]\n{raw}"
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
                            "[بيانات الترويسة وهوية المستند المستخلصة بصرياً (Metadata من الصفحة 1):\n"
                            f"{vis_hdr}\n]\n\n"
                        )
        except Exception:
            logger.debug("Page 1 visual letterhead check failed", exc_info=True)

    non_empty_pages = [p for p in chosen_pages if p.strip()]
    if not non_empty_pages:
        return ""

    formatted_pages = [
        f"--- [صفحة {i} من {num_pages}] ---\n{pt}" if num_pages > 1 else pt
        for i, pt in enumerate(chosen_pages, 1)
    ]
    final_text = banner_meta + "\n\n".join(formatted_pages)
    if final_text.strip():
        _cache_write(f"{file_hash}.v132", {"num_pages": num_pages, "used_vision": used_full_ocr, "text": final_text})
    return final_text


def _read_pdf_text_with_pdfium(file_content: bytes) -> str:
    with (
        _PDFIUM_LOCK,
        pypdfium2.PdfDocument(
            io.BytesIO(file_content),
            autoclose=True,
        ) as pdf_document,
    ):
        return _read_pdf_text(pdf_document)


def _read_pdf_text(pdf_document: pypdfium2.PdfDocument) -> str:
    text_parts = []
    for page in pdf_document:
        try:
            text_page = page.get_textpage()
            try:
                text_parts.append(text_page.get_text_range())
            finally:
                text_page.close()
        finally:
            page.close()
    return "".join(text_parts)


def _read_pdf_text_with_pypdf(file_content: bytes) -> str:
    pdf_reader = pypdf.PdfReader(io.BytesIO(file_content))
    try:
        text_parts = [page.extract_text() or "" for page in pdf_reader.pages]
        return "".join(text_parts)
    finally:
        pdf_reader.close()


def _read_fallback_pdf_text(file_content: bytes, *, default_text: str) -> str:
    try:
        fallback_text = _read_pdf_text_with_pypdf(file_content)
    except Exception:
        logger.debug("pypdf fallback failed for PDF text extraction", exc_info=True)
        return default_text
    if fallback_text.strip():
        logger.debug("pypdf fallback extracted text from PDF")
        return fallback_text
    logger.debug("pypdf fallback returned empty text for PDF")
    return default_text


def _extract_text_from_doc(
    file_content: bytes,
    *,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    """Extract text from a DOC file."""
    if not unstructured_api_config.api_url:
        msg = "Unstructured API URL is not configured for DOC file processing."
        raise TextExtractionError(msg)

    try:
        elements = _partition_file_via_unstructured_api(
            file_content,
            suffix=".doc",
            unstructured_api_config=unstructured_api_config,
        )
        return "\n".join([getattr(element, "text", "") for element in elements])
    except Exception as e:
        msg = f"Failed to extract text from DOC: {e!s}"
        raise TextExtractionError(msg) from e


def parser_docx_part(
    block: object,
    doc: Document,
    content_items: list[tuple[int, str, Table | Paragraph]],
    i: int,
) -> None:
    content_item: tuple[int, str, Table | Paragraph] | None = None
    match block:
        case CT_P():
            content_item = (i, "paragraph", Paragraph(block, doc))
        case CT_Tbl():
            content_item = (i, "table", Table(block, doc))
        case _:
            pass

    if content_item is not None:
        content_items.append(content_item)


def _normalize_docx_zip(file_content: bytes) -> bytes:
    r"""Some DOCX files (e.g. exported by Evernote on Windows) are malformed:
    ZIP entry names use backslash (\\) as path separator instead of the forward
    slash (/) required by both the ZIP spec and OOXML.  On Linux/Mac the entry
    "word\\document.xml" is never found when python-docx looks for
    "word/document.xml", which triggers a KeyError about a missing relationship.

    This function rewrites the ZIP in-memory, normalizing all entry names to
    use forward slashes without touching any actual document content.

    Returns:
        Normalized DOCX bytes, or the original bytes if the payload is not a ZIP.

    """
    try:
        with zipfile.ZipFile(io.BytesIO(file_content), "r") as zin:
            out_buf = io.BytesIO()
            with zipfile.ZipFile(
                out_buf,
                "w",
                compression=zipfile.ZIP_DEFLATED,
            ) as zout:
                _rewrite_docx_zip_entries(zin, zout)
            return out_buf.getvalue()
    except zipfile.BadZipFile:
        # Not a valid zip — return as-is and let python-docx report the real error
        return file_content


def _rewrite_docx_zip_entries(
    zin: zipfile.ZipFile,
    zout: zipfile.ZipFile,
) -> None:
    for item in zin.infolist():
        data = zin.read(item.filename)
        # Normalize backslash path separators to forward slash.
        item.filename = item.filename.replace("\\", "/")
        zout.writestr(item, data)


def _extract_text_from_docx(file_content: bytes) -> str:
    """Extract text from a DOCX file.
    For now support only paragraph and table add more if needed

    Returns:
        Extracted plain text content from the DOCX file.

    Raises:
        TextExtractionError: If the DOCX cannot be parsed after normalization and retry.

    """
    try:
        doc = _load_docx_document(file_content)
        text: list[str] = []
        for item_type, item in _iter_docx_content_items(doc):
            extracted_text = _extract_docx_item_text(item_type, item)
            if extracted_text is not None:
                text.append(extracted_text)
        return "\n".join(text)

    except Exception as e:
        logger.exception("Failed to extract text from DOCX")
        msg = f"Failed to extract text from DOCX: {e!s}"
        raise TextExtractionError(msg) from e


def extract_text_from_docx(file_content: bytes) -> str:
    """Extract text from a DOCX payload."""
    return _extract_text_from_docx(file_content)


def _load_docx_document(file_content: bytes) -> Document:
    try:
        return docx.Document(io.BytesIO(file_content))
    except Exception as e:
        logger.warning(
            "Failed to parse DOCX, attempting to normalize ZIP entry paths: %s",
            e,
            exc_info=e,
        )
        normalized_file_content = _normalize_docx_zip(file_content)
        return docx.Document(io.BytesIO(normalized_file_content))


def _iter_docx_content_items(doc: Document) -> list[tuple[str, Table | Paragraph]]:
    content_items: list[tuple[int, str, Table | Paragraph]] = []
    for index, part in enumerate(doc.element.body):
        parser_docx_part(part, doc, content_items, index)
    return [(item_type, item) for _, item_type, item in content_items]


def _extract_docx_item_text(item_type: str, item: Table | Paragraph) -> str | None:
    if item_type == "paragraph" and isinstance(item, Paragraph):
        return item.text
    if item_type == "table" and isinstance(item, Table):
        return _extract_docx_table_text(item)
    return None


def _extract_docx_table_text(item: Table) -> str | None:
    try:
        if not _docx_table_has_content(item):
            return None
        return _build_docx_markdown_table(item)
    except Exception as e:
        logger.warning("Failed to extract table from DOC: %s", e, exc_info=e)
        return None


def _docx_table_has_content(item: Table) -> bool:
    return any(any(cell.text.strip() for cell in row.cells) for row in item.rows)


def _build_docx_markdown_table(item: Table) -> str:
    cell_texts = [cell.text.replace("\n", "<br>") for cell in item.rows[0].cells]
    markdown_table = f"| {' | '.join(cell_texts)} |\n"
    markdown_table += f"| {' | '.join(['---'] * len(item.rows[0].cells))} |\n"
    for row in item.rows[1:]:
        row_cells = [cell.text.replace("\n", "<br>") for cell in row.cells]
        markdown_table += "| " + " | ".join(row_cells) + " |\n"
    return markdown_table


def _download_file_content(http_client: HttpClientProtocol, file: File) -> bytes:
    """Download the content of a file based on its transfer method."""
    if (
        file.transfer_method == FileTransferMethod.REMOTE_URL
        and file.remote_url is None
    ):
        msg = "Missing URL for remote file"
        raise FileDownloadError(msg)

    try:
        if (
            file.transfer_method == FileTransferMethod.REMOTE_URL
            and file.remote_url is not None
        ):
            response = http_client.get(file.remote_url)
            response.raise_for_status()
            return response.content
        return file_manager.download(file)
    except Exception as e:
        msg = f"Error downloading file: {e!s}"
        raise FileDownloadError(msg) from e


def download_file_content(http_client: HttpClientProtocol, file: File) -> bytes:
    """Download file content using the document extractor rules."""
    return _download_file_content(http_client, file)


def _extract_text_from_file(
    http_client: HttpClientProtocol,
    file: File,
    *,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    file_content = _download_file_content(http_client, file)
    if file.extension:
        extracted_text = _extract_text_by_file_extension(
            file_content=file_content,
            file_extension=file.extension,
            unstructured_api_config=unstructured_api_config,
        )
    elif file.mime_type:
        extracted_text = _extract_text_by_mime_type(
            file_content=file_content,
            mime_type=file.mime_type,
            unstructured_api_config=unstructured_api_config,
        )
    else:
        msg = "Unable to determine file type: MIME type or file extension is missing"
        raise UnsupportedFileTypeError(msg)
    return extracted_text


def _extract_text_from_csv(file_content: bytes) -> str:
    try:
        csv_file = io.StringIO(_decode_csv_text(file_content))
        return _rows_to_markdown_table(list(csv.reader(csv_file)))
    except Exception as e:
        msg = f"Failed to extract text from CSV: {e!s}"
        raise TextExtractionError(msg) from e


def _decode_csv_text(file_content: bytes) -> str:
    result = charset_normalizer.from_bytes(file_content).best()
    encoding = result.encoding if result else "utf-8"
    if not encoding:
        encoding = "utf-8"

    try:
        return file_content.decode(encoding, errors="ignore")
    except (UnicodeDecodeError, LookupError):
        return file_content.decode("utf-8", errors="ignore")


def _normalize_table_cell(cell: str) -> str:
    return cell.replace("\n", " ").replace("\r", "")


def _rows_to_markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""

    header_row = [_normalize_table_cell(cell) for cell in rows[0]]
    lines = [
        "| " + " | ".join(header_row) + " |\n",
        "| " + " | ".join(["-" * len(col) for col in rows[0]]) + " |\n",
    ]
    for row in rows[1:]:
        processed_row = [_normalize_table_cell(cell) for cell in row]
        lines.append("| " + " | ".join(processed_row) + " |\n")
    return "".join(lines)


def _extract_text_from_excel(file_content: bytes) -> str:
    """Extract text from an Excel file using pandas."""
    try:
        excel_file = pd.ExcelFile(io.BytesIO(file_content))
        return _excel_file_to_markdown(excel_file)
    except Exception as e:
        msg = f"Failed to extract text from Excel file: {e!s}"
        raise TextExtractionError(msg) from e


def _excel_file_to_markdown(excel_file: Any) -> str:
    markdown_tables = []
    for sheet_name in excel_file.sheet_names:
        markdown_table = _excel_sheet_to_markdown(excel_file, sheet_name)
        if markdown_table is not None:
            markdown_tables.append(markdown_table + "\n\n")
    return "".join(markdown_tables)


def _excel_sheet_to_markdown(
    excel_file: Any,
    sheet_name: str,
) -> str | None:
    try:
        return _parse_excel_sheet_to_markdown(excel_file, sheet_name)
    except (TypeError, ValueError):
        return None


def _parse_excel_sheet_to_markdown(
    excel_file: Any,
    sheet_name: str,
) -> str | None:
    df = excel_file.parse(sheet_name=sheet_name)
    if not isinstance(df, pd.DataFrame):
        return None
    normalized_df = _normalize_excel_dataframe(df.dropna(how="all"))
    return _excel_dataframe_to_markdown(normalized_df)


def _normalize_excel_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    df = df.map(lambda x: " ".join(str(x).splitlines()) if isinstance(x, str) else x)
    df.columns = pd.Index([" ".join(str(col).splitlines()) for col in df.columns])
    return df


def _excel_dataframe_to_markdown(df: pd.DataFrame) -> str:
    header_row = "| " + " | ".join(df.columns) + " |"
    separator_row = "| " + " | ".join(["-" * len(col) for col in df.columns]) + " |"
    data_rows = []
    for _, row in df.iterrows():
        data_rows.append("| " + " | ".join(map(str, row)) + " |")
    return "\n".join([header_row, separator_row, *data_rows])


def _extract_text_from_ppt(
    file_content: bytes,
    *,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    try:
        return _partition_unstructured_file(
            file_content,
            suffix=".ppt",
            unstructured_api_config=unstructured_api_config,
            load_local_partition=_load_partition_ppt,
            render_element=_render_unstructured_text_element,
        )
    except Exception as e:
        msg = f"Failed to extract text from PPT: {e!s}"
        raise TextExtractionError(msg) from e


def _extract_text_from_pptx(
    file_content: bytes,
    *,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    try:
        return _partition_unstructured_file(
            file_content,
            suffix=".pptx",
            unstructured_api_config=unstructured_api_config,
            load_local_partition=_load_partition_pptx,
            render_element=_render_unstructured_text_element,
        )
    except Exception as e:
        msg = f"Failed to extract text from PPTX: {e!s}"
        raise TextExtractionError(msg) from e


def _extract_text_from_epub(
    file_content: bytes,
    *,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    try:
        if unstructured_api_config.api_url:
            elements = _partition_unstructured_file_via_api(
                file_content,
                suffix=".epub",
                unstructured_api_config=unstructured_api_config,
            )
            return "\n".join(
                _render_unstructured_text_element(element) for element in elements
            )
        return _extract_epub_text(file_content)
    except Exception as e:
        msg = f"Failed to extract text from EPUB: {e!s}"
        raise TextExtractionError(msg) from e


def _extract_epub_text(file_content: bytes) -> str:
    from unstructured.partition.html import (  # ruff:ignore[import-outside-top-level]
        partition_html,
    )

    with zipfile.ZipFile(io.BytesIO(file_content)) as archive:
        container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
        rootfile = container.find(".//{*}rootfile")
        package_path = rootfile.get("full-path") if rootfile is not None else None
        if not package_path:
            msg = "EPUB package path is missing"
            raise ValueError(msg)

        package_path = unquote(urlsplit(package_path).path).lstrip("/")
        package = ElementTree.fromstring(archive.read(package_path))
        manifest = {
            item.attrib["id"]: item.attrib["href"]
            for item in package.findall(".//{*}manifest/{*}item")
            if "id" in item.attrib and "href" in item.attrib
        }
        extracted_text: list[str] = []
        for itemref in package.findall(".//{*}spine/{*}itemref"):
            href = manifest.get(itemref.get("idref", ""))
            if href is None:
                continue
            chapter_path = posixpath.normpath(
                posixpath.join(
                    posixpath.dirname(package_path),
                    unquote(urlsplit(href).path),
                ),
            ).lstrip("/")
            with io.BytesIO(archive.read(chapter_path)) as chapter:
                extracted_text.extend(
                    str(element) for element in partition_html(file=chapter)
                )
        return "\n".join(extracted_text)


def _extract_text_from_odt(
    file_content: bytes,
    *,
    unstructured_api_config: UnstructuredApiConfig,
) -> str:
    try:
        if unstructured_api_config.api_url:
            elements = _partition_unstructured_file_via_api(
                file_content,
                suffix=".odt",
                unstructured_api_config=unstructured_api_config,
            )
            return "\n".join(
                _render_unstructured_text_element(element) for element in elements
            )
        with io.BytesIO(file_content) as file:
            return OdfDocument(file).get_formatted_text().strip()
    except Exception as e:
        msg = f"Failed to extract text from ODT: {e!s}"
        raise TextExtractionError(msg) from e


def _partition_unstructured_file(
    file_content: bytes,
    *,
    suffix: str,
    unstructured_api_config: UnstructuredApiConfig,
    load_local_partition: Callable[[], Callable[..., Sequence[Any]]],
    render_element: Callable[[Any], str],
) -> str:
    if unstructured_api_config.api_url:
        elements = _partition_unstructured_file_via_api(
            file_content,
            suffix=suffix,
            unstructured_api_config=unstructured_api_config,
        )
    else:
        elements = _partition_unstructured_file_locally(
            file_content,
            load_local_partition=load_local_partition,
        )
    return "\n".join([render_element(element) for element in elements])


def _partition_unstructured_file_via_api(
    file_content: bytes,
    *,
    suffix: str,
    unstructured_api_config: UnstructuredApiConfig,
) -> Sequence[Any]:
    return _partition_file_via_unstructured_api(
        file_content,
        suffix=suffix,
        unstructured_api_config=unstructured_api_config,
    )


def _partition_unstructured_file_locally(
    file_content: bytes,
    *,
    load_local_partition: Callable[[], Callable[..., Sequence[Any]]],
) -> Sequence[Any]:
    partition_file = load_local_partition()
    with io.BytesIO(file_content) as file:
        return partition_file(file=file)


def _load_partition_ppt() -> Callable[..., Sequence[Any]]:
    from unstructured.partition.ppt import (  # ruff:ignore[import-outside-top-level]
        partition_ppt,
    )

    return partition_ppt


def _load_partition_pptx() -> Callable[..., Sequence[Any]]:
    from unstructured.partition.pptx import (  # ruff:ignore[import-outside-top-level]
        partition_pptx,
    )

    return partition_pptx


def _render_unstructured_text_element(element: Any) -> str:
    return getattr(element, "text", "")


def _extract_text_from_eml(file_content: bytes) -> str:
    try:
        from unstructured.partition.email import (  # ruff:ignore[import-outside-top-level]
            partition_email,
        )

        with io.BytesIO(file_content) as file:
            elements = partition_email(file=file)
        return "\n".join([str(element) for element in elements])
    except Exception as e:
        msg = f"Failed to extract text from EML: {e!s}"
        raise TextExtractionError(msg) from e


def _extract_text_from_msg(file_content: bytes) -> str:
    try:
        from unstructured.partition.msg import (  # ruff:ignore[import-outside-top-level]
            partition_msg,
        )

        with io.BytesIO(file_content) as file:
            elements = partition_msg(file=file)
        return "\n".join([str(element) for element in elements])
    except Exception as e:
        msg = f"Failed to extract text from MSG: {e!s}"
        raise TextExtractionError(msg) from e


def _extract_text_from_vtt(vtt_bytes: bytes) -> str:
    text = _extract_text_from_plain_text(vtt_bytes)

    # remove bom
    text = text.lstrip("\ufeff")

    raw_results = [
        (caption.voice, caption.text) for caption in webvtt.from_string(text)
    ]

    # Merge consecutive utterances by the same speaker
    merged_results = []
    if raw_results:
        current_speaker, current_text = raw_results[0]

        for i in range(1, len(raw_results)):
            spk, txt = raw_results[i]
            if spk is None:
                merged_results.append((None, current_text))
                continue

            if spk == current_speaker:
                # If it is the same speaker, merge the utterances (joined by space)
                current_text += " " + txt
            else:
                # If the speaker changes, register the utterance so far and move on
                merged_results.append((current_speaker, current_text))
                current_speaker, current_text = spk, txt

        # Add the last element
        merged_results.append((current_speaker, current_text))
    else:
        merged_results = raw_results

    # Return the result in the specified format: Speaker "text" style
    formatted = [f'{spk or ""} "{txt}"' for spk, txt in merged_results]
    return "\n".join(formatted)


def _extract_text_from_properties(file_content: bytes) -> str:
    try:
        text = _extract_text_from_plain_text(file_content)
        return _format_properties_text(text)
    except Exception as e:
        msg = f"Failed to extract text from properties file: {e!s}"
        raise TextExtractionError(msg) from e


def _format_properties_text(text: str) -> str:
    return "\n".join(_format_property_line(line) for line in text.splitlines())


def _format_property_line(line: str) -> str:
    stripped_line = line.strip()
    if not stripped_line or stripped_line.startswith(("#", "!")):
        return stripped_line

    if "=" in stripped_line:
        key, value = stripped_line.split("=", 1)
    elif ":" in stripped_line:
        key, value = stripped_line.split(":", 1)
    else:
        key, value = stripped_line, ""

    return f"{key.strip()}: {value.strip()}"


def _build_text_extractor_registry() -> _TextExtractorRegistry:
    return _TextExtractorRegistry((
        _ExtractorRegistration(
            name="plain_text",
            extractor=_extract_text_from_plain_text,
            mime_types=_MIME_PLAIN_TEXT_TYPES,
            file_extensions=_EXTENSION_PLAIN_TEXT_TYPES,
        ),
        _ExtractorRegistration(
            name="json",
            extractor=_extract_text_from_json,
            mime_types=frozenset({"application/json"}),
            file_extensions=frozenset({".json"}),
        ),
        _ExtractorRegistration(
            name="yaml",
            extractor=_extract_text_from_yaml,
            mime_types=frozenset({"application/x-yaml", "text/yaml"}),
            file_extensions=frozenset({".yaml", ".yml"}),
        ),
        _ExtractorRegistration(
            name="pdf",
            extractor=_extract_text_from_pdf,
            mime_types=frozenset({"application/pdf"}),
            file_extensions=frozenset({".pdf"}),
        ),
        _ExtractorRegistration(
            name="doc",
            extractor=_extract_text_from_doc,
            mime_types=frozenset({"application/msword"}),
            file_extensions=frozenset({".doc"}),
            requires_unstructured_config=True,
        ),
        _ExtractorRegistration(
            name="docx",
            extractor=_extract_text_from_docx,
            mime_types=frozenset({
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            }),
            file_extensions=frozenset({".docx"}),
        ),
        _ExtractorRegistration(
            name="csv",
            extractor=_extract_text_from_csv,
            mime_types=frozenset({"text/csv"}),
            file_extensions=frozenset({".csv"}),
        ),
        _ExtractorRegistration(
            name="excel",
            extractor=_extract_text_from_excel,
            mime_types=frozenset({
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                "application/vnd.ms-excel",
            }),
            file_extensions=frozenset({".xls", ".xlsx"}),
        ),
        _ExtractorRegistration(
            name="ppt",
            extractor=_extract_text_from_ppt,
            mime_types=frozenset({"application/vnd.ms-powerpoint"}),
            file_extensions=frozenset({".ppt"}),
            requires_unstructured_config=True,
        ),
        _ExtractorRegistration(
            name="pptx",
            extractor=_extract_text_from_pptx,
            mime_types=frozenset({
                "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            }),
            file_extensions=frozenset({".pptx"}),
            requires_unstructured_config=True,
        ),
        _ExtractorRegistration(
            name="epub",
            extractor=_extract_text_from_epub,
            mime_types=frozenset({"application/epub+zip"}),
            file_extensions=frozenset({".epub"}),
            requires_unstructured_config=True,
        ),
        _ExtractorRegistration(
            name="odt",
            extractor=_extract_text_from_odt,
            mime_types=frozenset({"application/vnd.oasis.opendocument.text"}),
            file_extensions=frozenset({".odt"}),
            requires_unstructured_config=True,
        ),
        _ExtractorRegistration(
            name="eml",
            extractor=_extract_text_from_eml,
            mime_types=frozenset({"message/rfc822"}),
            file_extensions=frozenset({".eml"}),
        ),
        _ExtractorRegistration(
            name="msg",
            extractor=_extract_text_from_msg,
            mime_types=frozenset({"application/vnd.ms-outlook"}),
            file_extensions=frozenset({".msg"}),
        ),
        _ExtractorRegistration(
            name="vtt",
            extractor=_extract_text_from_vtt,
            mime_types=frozenset({"text/vtt"}),
        ),
        _ExtractorRegistration(
            name="properties",
            extractor=_extract_text_from_properties,
            mime_types=frozenset({"text/properties"}),
            file_extensions=frozenset({".properties"}),
        ),
    ))


_TEXT_EXTRACTOR_REGISTRY = _build_text_extractor_registry()

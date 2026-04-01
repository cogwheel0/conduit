from __future__ import annotations

from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
import httpx
import json
import csv
import os
import time
from pathlib import Path
import re
import uuid
from typing import Any

from pypdf import PdfReader
from docx import Document
from openpyxl import load_workbook

from .budget import build_budget, trim_recent_messages
from .store import load_conversation, save_conversation
from .summarizer import summarize_messages
from .rag import (
    ensure_collection,
    add_document,
    search_documents,
    list_collections,
    create_collection_marker,
    qdrant,
    COLLECTION_NAME,
)
from qdrant_client.models import Filter, FieldCondition, MatchValue

app = FastAPI(title="Qonduit Memory Gateway")


@app.on_event("startup")
async def startup() -> None:
    ensure_collection()


LLAMA_BASE = "http://192.168.5.5:8080"

UPLOAD_DIR = "/mnt/models/qonduit_uploads"

TEXT_EXTENSIONS = {
    ".txt", ".md", ".json", ".csv",
    ".py", ".c", ".cpp", ".h", ".hpp",
    ".java", ".kt", ".kts",
    ".xml", ".html", ".css", ".js", ".ts",
    ".sql", ".yaml", ".yml", ".toml", ".ini", ".sh",
    ".go", ".rs", ".swift", ".php", ".rb", ".pl", ".lua",
    ".vhdl", ".vhd", ".v", ".dart",
}

DEFAULT_SYSTEM_PROMPT = (
    "You are Qonduit, a practical local coding and systems assistant. "
    "Be accurate, structured, and concise. "
    "For any non-trivial task, think in phases and present the answer in small, bounded chunks. "

    "Core response rules: "
    "1. Break complex work into numbered steps or short sections. "
    "2. Prefer the smallest complete useful answer over a long answer. "
    "3. Do not try to fit an oversized answer into one response. "
    "4. If the full answer would be long, give the first useful chunk only, stop at a natural boundary, and end with: "
    "\"Reply with continue for the next chunk.\" "
    "5. Never ramble. Avoid repetition and unnecessary explanation. "
    "6. For coding tasks, give the plan first if the task is large, then provide only the current step's code. "
    "7. For debugging, start with the most likely cause, then the next concrete action. "
    "8. For infrastructure or setup tasks, prefer exact commands and explicit file edits. "
    "9. Keep each response self-contained and easy to apply immediately. "
    "10. If the user asks for full detail, still split the answer into manageable parts instead of one huge block. "

    "Formatting rules: "
    "Use short headings when helpful. "
    "Use short numbered steps for procedures. "
    "Keep paragraphs short. "
    "When giving code, include only code needed for the current step unless the user explicitly asks for the full file. "

    "Behavior rules: "
    "If context is large or the task is broad, summarize the plan briefly before details. "
    "If multiple valid approaches exist, recommend one and keep alternatives brief. "
    "If the answer risks being cut off, compress and stop cleanly rather than continuing mid-thought. "
    "If relevant information exists in the provided context, conversation summary, or knowledge base excerpts, use it directly instead of guessing. "
    "Optimize for reliability, clarity, and completion over verbosity."
)


class ChatMessage(BaseModel):
    role: str
    content: str


class GatewayChatRequest(BaseModel):
    conversation_id: str
    messages: list[ChatMessage]
    model: str
    context_size: int = Field(default=65536)
    max_tokens: int = Field(default=2048)
    temperature: float = Field(default=0.7)
    rag_collection: str | None = None


class RagIngestRequest(BaseModel):
    text: str
    source: str = "manual_test"
    collection: str = "default"
    document_name: str = "untitled"


class RagSearchRequest(BaseModel):
    query: str
    limit: int = 4
    collection: str = "default"


class RagCollectionCreateRequest(BaseModel):
    name: str


class RagCollectionDeleteRequest(BaseModel):
    name: str


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "service": "qonduit-memory-gateway"}


def get_request_user_id(request: Request) -> str:
    raw = request.headers.get("X-Qonduit-User", "").strip().lower()
    safe = "".join(c for c in raw if c.isalnum() or c in ("-", "_"))
    return safe or "default"


def ensure_upload_dir() -> None:
    os.makedirs(UPLOAD_DIR, exist_ok=True)


def sanitize_filename(filename: str) -> str:
    cleaned = filename.strip()
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", cleaned)
    cleaned = cleaned.strip("._")
    return cleaned or "uploaded_file"


def build_saved_upload_path(user_id: str, collection_name: str, filename: str) -> str:
    safe_user = sanitize_filename(user_id)
    safe_collection = sanitize_filename(collection_name)
    safe_filename = sanitize_filename(filename)
    file_id = str(uuid.uuid4())
    collection_dir = os.path.join(UPLOAD_DIR, safe_user, safe_collection)
    os.makedirs(collection_dir, exist_ok=True)
    return os.path.join(collection_dir, f"{file_id}__{safe_filename}")


def collection_upload_dir(user_id: str, collection_name: str) -> str:
    safe_user = sanitize_filename(user_id)
    safe_collection = sanitize_filename(collection_name)
    return os.path.join(UPLOAD_DIR, safe_user, safe_collection)


def delete_collection_upload_dir(user_id: str, collection_name: str) -> int:
    import shutil

    target_dir = collection_upload_dir(user_id, collection_name)
    if not os.path.exists(target_dir):
        return 0

    file_count = 0
    for _, _, files in os.walk(target_dir):
        file_count += len(files)

    shutil.rmtree(target_dir, ignore_errors=True)
    return file_count


def code_edit_artifact_dir(user_id: str) -> str:
    safe_user = sanitize_filename(user_id)
    target_dir = os.path.join(UPLOAD_DIR, safe_user, "__code_edits__")
    os.makedirs(target_dir, exist_ok=True)
    return target_dir


def save_code_edit_artifact(user_id: str, filename: str, content: str) -> dict[str, Any]:
    safe_name = sanitize_filename(Path(filename).name or "modified_file.txt")
    if not Path(safe_name).suffix:
        safe_name = f"{safe_name}.txt"

    artifact_id = str(uuid.uuid4())
    saved_path = os.path.join(code_edit_artifact_dir(user_id), f"{artifact_id}__{safe_name}")

    with open(saved_path, "w", encoding="utf-8") as f:
        f.write(content)

    return {
        "id": artifact_id,
        "name": safe_name,
        "saved_path": saved_path,
        "size_bytes": len(content.encode("utf-8")),
        "type": "code_edit_file",
    }


def chunk_text(text: str, chunk_size: int = 1200, overlap: int = 200) -> list[str]:
    cleaned = text.strip()
    if not cleaned:
        return []

    chunks: list[str] = []
    start = 0
    text_len = len(cleaned)

    while start < text_len:
        end = min(start + chunk_size, text_len)
        chunk = cleaned[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= text_len:
            break
        start = max(end - overlap, 0)

    return chunks


def extract_text_from_txt_like(file_path: str) -> str:
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def extract_text_from_pdf(file_path: str) -> str:
    reader = PdfReader(file_path)
    parts: list[str] = []

    for page in reader.pages:
        try:
            page_text = page.extract_text() or ""
        except Exception:
            page_text = ""
        if page_text.strip():
            parts.append(page_text)

    return "\n\n".join(parts)


def extract_text_from_docx(file_path: str) -> str:
    doc = Document(file_path)
    parts = [p.text for p in doc.paragraphs if p.text and p.text.strip()]
    return "\n\n".join(parts)


def extract_text_from_csv_file(file_path: str) -> str:
    rows: list[str] = []
    with open(file_path, "r", encoding="utf-8", errors="ignore", newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            rows.append(" | ".join(cell.strip() for cell in row))
    return "\n".join(rows)


def extract_text_from_xlsx(file_path: str) -> str:
    wb = load_workbook(file_path, data_only=True)
    parts: list[str] = []

    for sheet in wb.worksheets:
        parts.append(f"# Sheet: {sheet.title}")
        for row in sheet.iter_rows(values_only=True):
            values = ["" if cell is None else str(cell) for cell in row]
            line = " | ".join(v.strip() for v in values if str(v).strip())
            if line:
                parts.append(line)

    return "\n".join(parts)


def extract_text_from_file(file_path: str, suffix: str) -> str:
    suffix = suffix.lower()

    if suffix in TEXT_EXTENSIONS:
        return extract_text_from_txt_like(file_path)

    if suffix == ".pdf":
        return extract_text_from_pdf(file_path)

    if suffix == ".docx":
        return extract_text_from_docx(file_path)

    if suffix == ".csv":
        return extract_text_from_csv_file(file_path)

    if suffix in {".xlsx", ".xls"}:
        return extract_text_from_xlsx(file_path)

    raise ValueError(f"Unsupported file type: {suffix}")


def latest_user_text(messages: list[ChatMessage]) -> str:
    for msg in reversed(messages):
        if msg.role == "user":
            return msg.content
    return ""


def _debug_preview(text: str, limit: int = 280) -> str:
    preview = text.replace("\n", "\\n")
    if len(preview) > limit:
        return preview[:limit] + "...(truncated)"
    return preview


def debug_code_edit_event(event: str, **kwargs: Any) -> None:
    parts: list[str] = []
    for key, value in kwargs.items():
        try:
            rendered = str(value)
        except Exception:
            rendered = "<unrenderable>"
        parts.append(f"{key}={rendered}")
    print(f"[code-edit-debug] {event} | " + " | ".join(parts), flush=True)


def is_code_edit_request(text: str) -> bool:
    lowered = text.lower()
    return (
        "code edit" in lowered
        or "modified file" in lowered
        or "update this file" in lowered
        or "rewrite this file" in lowered
    )


def extract_requested_filename(text: str) -> str | None:
    patterns = [
        r"file:\s*([^\n\r]+)",
        r"for file:\s*([^\n\r]+)",
        r"filename:\s*([^\n\r]+)",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if match:
            value = match.group(1).strip()
            if value:
                return Path(value).name
    return None


def extract_inline_file_contents(text: str) -> str:
    patterns = [
        r"Current file contents:\s*\n(?P<body>.*)$",
        r"Current file:\s*\n(?P<body>.*)$",
        r"<<<FILE\s*\n(?P<body>.*?)\nFILE\s*$",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE | re.DOTALL)
        if match:
            body = match.group("body").strip("\n\r")
            if body.strip():
                return body
    return ""


def extract_code_edit_instruction(text: str) -> str:
    working = text

    working = re.sub(
        r"^\s*Code edit request for file:\s*[^\n\r]+\s*",
        "",
        working,
        flags=re.IGNORECASE,
    )
    working = re.sub(
        r"Current file contents:\s*\n.*$",
        "",
        working,
        flags=re.IGNORECASE | re.DOTALL,
    )
    working = re.sub(
        r"Current file:\s*\n.*$",
        "",
        working,
        flags=re.IGNORECASE | re.DOTALL,
    )
    working = re.sub(
        r"<<<FILE\s*\n.*?\nFILE\s*$",
        "",
        working,
        flags=re.IGNORECASE | re.DOTALL,
    )

    return working.strip()


def build_code_edit_model_input(
    requested_filename: str | None,
    instruction: str,
    file_contents: str,
) -> str:
    target_name = requested_filename or "modified_file.txt"
    safe_instruction = instruction.strip() or "Update the file as requested."

    return (
        f"Target file: {target_name}\n\n"
        f"Edit instruction:\n{safe_instruction}\n\n"
        "Current file contents:\n"
        f"{file_contents}"
    )


def build_code_edit_contract_system_prompt(requested_filename: str | None) -> str:
    target_name = requested_filename or "modified_file.txt"
    return (
        "You are handling a code edit request. "
        "You will be given the target file name, a concrete edit instruction, and the current file contents. "
        "Use the provided file contents as the source of truth. "
        "Do not return a unified diff. "
        "Do not return markdown fences. "
        "Do not include conversational filler. "
        "Return only valid JSON with this exact schema:\n"
        "{\n"
        '  "executive_summary": ["short bullet", "short bullet"],\n'
        '  "change_summary": ["technical bullet", "technical bullet"],\n'
        '  "patch_confidence": "high|medium|low",\n'
        '  "modified_file": {\n'
        f'    "name": "{target_name}",\n'
        '    "content": "full updated file contents here"\n'
        "  }\n"
        "}\n"
        "Rules:\n"
        "1. executive_summary must be short and human-readable.\n"
        "2. change_summary must be technical and concise.\n"
        "3. patch_confidence must be exactly one of: high, medium, low.\n"
        "4. modified_file.content must contain the full updated file contents.\n"
        "5. Never return a diff.\n"
        "6. Never omit modified_file.content if you can complete the edit.\n"
        "7. Only use low patch_confidence when the instruction is ambiguous or the supplied file contents are clearly insufficient.\n"
    )


def extract_json_object(raw: str) -> str | None:
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    return raw[start:end + 1]


def normalize_summary_lines(value: Any) -> list[str]:
    if isinstance(value, list):
        items = []
        for item in value:
            text = str(item).strip()
            if text:
                items.append(text)
        return items

    if isinstance(value, str):
        lines = []
        for line in value.splitlines():
            cleaned = line.strip().lstrip("-•* ").strip()
            if cleaned:
                lines.append(cleaned)
        return lines

    return []


def normalize_patch_confidence(value: Any) -> str:
    text = str(value or "").strip().lower()
    if text in {"high", "medium", "low"}:
        return text
    return "low"


def parse_code_edit_response(raw: str, requested_filename: str | None) -> dict[str, Any]:
    default_name = requested_filename or "modified_file.txt"
    default = {
        "executive_summary": [
            "The model did not return the requested structured code-edit response."
        ],
        "change_summary": [
            "No attachment-ready modified file was produced from the response."
        ],
        "patch_confidence": "low",
        "modified_file": {
            "name": default_name,
            "content": "",
        },
    }

    blob = extract_json_object(raw)
    if not blob:
        return default

    try:
        parsed = json.loads(blob)
    except Exception:
        return default

    executive_summary = normalize_summary_lines(parsed.get("executive_summary"))
    change_summary = normalize_summary_lines(parsed.get("change_summary"))
    patch_confidence = normalize_patch_confidence(parsed.get("patch_confidence"))

    modified_file = parsed.get("modified_file", {})
    if not isinstance(modified_file, dict):
        modified_file = {}

    modified_name = str(
        modified_file.get("name")
        or parsed.get("modified_file_name")
        or default_name
    ).strip() or default_name

    modified_content = str(
        modified_file.get("content")
        or parsed.get("modified_file_content")
        or ""
    )

    if not executive_summary:
        executive_summary = ["Prepared a code-edit response."]
    if not change_summary:
        if modified_content.strip():
            change_summary = [f"Prepared updated file contents for {modified_name}."]
        else:
            change_summary = ["No updated file contents were provided by the model."]

    return {
        "executive_summary": executive_summary,
        "change_summary": change_summary,
        "patch_confidence": patch_confidence,
        "modified_file": {
            "name": Path(modified_name).name or default_name,
            "content": modified_content,
        },
    }


def format_code_edit_summary(parsed: dict[str, Any], artifact: dict[str, Any] | None) -> str:
    lines: list[str] = []

    lines.append("Executive Summary")
    for item in parsed["executive_summary"]:
        lines.append(f"• {item}")

    lines.append("")
    lines.append("Change Summary")
    for item in parsed["change_summary"]:
        lines.append(f"• {item}")

    lines.append("")
    lines.append(f"Patch Confidence: {str(parsed['patch_confidence']).upper()}")

    if artifact is not None:
        lines.append("")
        lines.append(f"Prepared File: {artifact['name']}")
        lines.append(f"Saved Path: {artifact['saved_path']}")

    return "\n".join(lines).strip()


def sse_chunk(model: str, content: str = "", finish_reason: str | None = None) -> str:
    payload = {
        "id": f"chatcmpl-qonduit-{uuid.uuid4().hex}",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": {"content": content} if content else {},
                "finish_reason": finish_reason,
            }
        ],
    }
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


def split_for_stream(text: str, chunk_size: int = 180) -> list[str]:
    if not text:
        return []
    parts: list[str] = []
    start = 0
    while start < len(text):
        parts.append(text[start:start + chunk_size])
        start += chunk_size
    return parts


@app.post("/rag/test-ingest")
async def rag_test_ingest(req: RagIngestRequest, request: Request) -> dict:
    user_id = get_request_user_id(request)
    doc_id = await add_document(
        text=req.text,
        metadata={
            "source": req.source,
            "collection": req.collection,
            "document_name": req.document_name,
        },
        user_id=user_id,
    )
    return {"ok": True, "id": doc_id}


@app.post("/rag/test-search")
async def rag_test_search(req: RagSearchRequest, request: Request) -> dict:
    user_id = get_request_user_id(request)
    results = await search_documents(
        req.query,
        limit=req.limit,
        collection=req.collection,
        user_id=user_id,
    )
    return {"ok": True, "results": results}


@app.get("/rag/collections")
async def rag_list_collections(request: Request) -> dict:
    user_id = get_request_user_id(request)
    return {"ok": True, "collections": list_collections(user_id=user_id)}


@app.post("/rag/collections/create")
async def rag_create_collection(req: RagCollectionCreateRequest, request: Request) -> dict:
    user_id = get_request_user_id(request)
    name = req.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Collection name cannot be empty")

    await create_collection_marker(name, user_id=user_id)
    return {"ok": True, "collection": name}


@app.post("/rag/collections/delete")
async def rag_delete_collection(req: RagCollectionDeleteRequest, request: Request) -> dict:
    user_id = get_request_user_id(request)
    collection_name = req.name.strip()
    if not collection_name:
        raise HTTPException(status_code=400, detail="Collection name cannot be empty")

    deleted_points = 0

    try:
        points, _ = qdrant.scroll(
            collection_name=COLLECTION_NAME,
            scroll_filter=Filter(
                must=[
                    FieldCondition(
                        key="collection",
                        match=MatchValue(value=collection_name),
                    ),
                    FieldCondition(
                        key="user_id",
                        match=MatchValue(value=user_id),
                    ),
                ]
            ),
            limit=10000,
            with_payload=False,
            with_vectors=False,
        )

        point_ids = [p.id for p in points if p.id is not None]
        if point_ids:
            qdrant.delete(
                collection_name=COLLECTION_NAME,
                points_selector=point_ids,
            )
            deleted_points = len(point_ids)

        deleted_files = delete_collection_upload_dir(user_id, collection_name)

        return {
            "ok": True,
            "collection": collection_name,
            "deleted_points": deleted_points,
            "deleted_files": deleted_files,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete collection: {e}")


@app.post("/rag/upload")
async def rag_upload_document(
    request: Request,
    file: UploadFile = File(...),
    collection: str = Form(...),
    source: str = Form("qonduit_upload"),
) -> dict:
    ensure_upload_dir()

    user_id = get_request_user_id(request)
    collection_name = collection.strip()
    if not collection_name:
        raise HTTPException(status_code=400, detail="Collection cannot be empty")

    filename = file.filename or "uploaded_file"
    filename = sanitize_filename(filename)
    suffix = Path(filename).suffix.lower()

    if not suffix:
        raise HTTPException(status_code=400, detail="Uploaded file must have an extension")

    saved_path = build_saved_upload_path(user_id, collection_name, filename)

    try:
        with open(saved_path, "wb") as f:
            content = await file.read()
            f.write(content)

        extracted_text = extract_text_from_file(saved_path, suffix)
        if not extracted_text.strip():
            raise HTTPException(status_code=400, detail="No readable text found in file")

        chunks = chunk_text(extracted_text)
        if not chunks:
            raise HTTPException(status_code=400, detail="No text chunks generated from file")

        chunk_ids: list[str] = []
        for idx, chunk in enumerate(chunks):
            chunk_id = await add_document(
                text=chunk,
                metadata={
                    "source": source,
                    "collection": collection_name,
                    "document_name": filename,
                    "chunk_index": idx,
                    "file_type": suffix,
                    "saved_path": saved_path,
                },
                user_id=user_id,
            )
            chunk_ids.append(chunk_id)

        return {
            "ok": True,
            "collection": collection_name,
            "document_name": filename,
            "chunks_added": len(chunk_ids),
            "saved_path": saved_path,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to upload document: {e}")


@app.post("/v1/chat/completions")
async def chat(req: GatewayChatRequest, request: Request) -> dict:
    user_id = get_request_user_id(request)
    state = load_conversation(req.conversation_id)

    prior_recent = state.get("recent_messages", [])
    summary = state.get("summary", "")

    incoming = [m.model_dump() for m in req.messages]
    combined_recent = prior_recent + incoming

    trimmed_recent, _ = trim_recent_messages(
        combined_recent,
        summary=summary,
        system_prompt=DEFAULT_SYSTEM_PROMPT,
        context_size=req.context_size,
    )

    overflow_count = len(combined_recent) - len(trimmed_recent)

    if overflow_count > 0:
        older = combined_recent[:overflow_count]
        summary = await summarize_messages(req.model, summary, older)

    remaining_recent = combined_recent[overflow_count:]
    trimmed_recent, prompt_tokens = trim_recent_messages(
        remaining_recent,
        summary=summary,
        system_prompt=DEFAULT_SYSTEM_PROMPT,
        context_size=req.context_size,
    )

    budget = build_budget(req.context_size)
    max_tokens = min(req.max_tokens, budget.reserved_output)

    latest_text = latest_user_text(req.messages)
    requested_filename = extract_requested_filename(latest_text)
    code_edit_mode = is_code_edit_request(latest_text)
    code_edit_instruction = extract_code_edit_instruction(latest_text) if code_edit_mode else ""
    code_edit_file_contents = extract_inline_file_contents(latest_text) if code_edit_mode else ""

    debug_code_edit_event(
        "incoming_request",
        conversation_id=req.conversation_id,
        user_id=user_id,
        latest_user_preview=_debug_preview(latest_text),
        requested_filename=requested_filename or "",
        code_edit_mode=code_edit_mode,
        inline_file_chars=len(code_edit_file_contents),
        inline_file_present=bool(code_edit_file_contents.strip()),
    )

    rag_results = []
    rag_chunks = []

    if latest_text.strip():
        try:
            rag_results = await search_documents(
                latest_text,
                limit=2,
                collection=req.rag_collection or req.conversation_id,
                user_id=user_id,
            )
            rag_chunks = [
                item["text"].strip()
                for item in rag_results
                if item.get("text", "").strip()
            ]
        except Exception:
            rag_results = []
            rag_chunks = []

    rag_context = "\n\n".join(rag_chunks)

    debug_code_edit_event(
        "retrieval_result",
        rag_results=len(rag_results),
        rag_context_chars=len(rag_context),
        rag_preview=_debug_preview(rag_context),
    )

    final_messages = [
        {"role": "system", "content": DEFAULT_SYSTEM_PROMPT},
        {"role": "system", "content": f"Rolling summary:\n{summary or '(none)'}"},
    ]

    if rag_context:
        final_messages.append(
            {
                "role": "system",
                "content": (
                    "Relevant retrieved knowledge:\n"
                    f"{rag_context}"
                ),
            }
        )

    recent_for_model = list(trimmed_recent)

    if code_edit_mode:
        final_messages.append(
            {
                "role": "system",
                "content": build_code_edit_contract_system_prompt(requested_filename),
            }
        )

        if recent_for_model and recent_for_model[-1].get("role") == "user":
            recent_for_model = recent_for_model[:-1]

        if code_edit_file_contents.strip():
            recent_for_model.append(
                {
                    "role": "user",
                    "content": build_code_edit_model_input(
                        requested_filename,
                        code_edit_instruction,
                        code_edit_file_contents,
                    ),
                }
            )

    final_messages.extend(recent_for_model)

    if code_edit_mode:
        debug_code_edit_event(
            "code_edit_model_input",
            final_user_preview=_debug_preview(recent_for_model[-1]["content"]) if recent_for_model and recent_for_model[-1].get("role") == "user" else "",
            final_user_chars=len(recent_for_model[-1]["content"]) if recent_for_model and recent_for_model[-1].get("role") == "user" else 0,
        )

    state["summary"] = summary
    state["recent_messages"] = trimmed_recent[-8:]
    state["last_model"] = req.model
    state["last_context_size"] = req.context_size
    state["last_prompt_tokens"] = prompt_tokens
    state["last_reserved_output"] = budget.reserved_output
    save_conversation(req.conversation_id, state)

    payload = {
        "model": req.model,
        "messages": final_messages,
        "max_tokens": max_tokens,
        "temperature": min(req.temperature, 0.2) if code_edit_mode else req.temperature,
        "stream": not code_edit_mode,
    }

    async def event_stream():
        if code_edit_mode:
            if not code_edit_file_contents.strip():
                debug_code_edit_event(
                    "code_edit_missing_file_contents",
                    requested_filename=requested_filename or "",
                    latest_user_preview=_debug_preview(latest_text),
                )
                parsed = {
                    "executive_summary": [
                        "No file contents were included with this code edit request."
                    ],
                    "change_summary": [
                        "The gateway only received the instruction text, so no modified file could be produced."
                    ],
                    "patch_confidence": "low",
                    "modified_file": {
                        "name": requested_filename or "modified_file.txt",
                        "content": "",
                    },
                }
            else:
                debug_code_edit_event(
                    "code_edit_llama_request",
                    requested_filename=requested_filename or "",
                    instruction_preview=_debug_preview(code_edit_instruction),
                    file_chars=len(code_edit_file_contents),
                    final_message_count=len(final_messages),
                )
                async with httpx.AsyncClient(timeout=300.0) as client:
                    r = await client.post(f"{LLAMA_BASE}/v1/chat/completions", json=payload)
                    if r.status_code >= 400:
                        raise HTTPException(status_code=r.status_code, detail=r.text)
                    data = r.json()

                raw_assistant = data["choices"][0]["message"]["content"]
                parsed = parse_code_edit_response(raw_assistant, requested_filename)

                debug_code_edit_event(
                    "code_edit_llama_response",
                    raw_preview=_debug_preview(raw_assistant),
                    parsed_filename=parsed.get("modified_file", {}).get("name", ""),
                    parsed_content_chars=len(str(parsed.get("modified_file", {}).get("content", ""))),
                    patch_confidence=parsed.get("patch_confidence", ""),
                )

            artifact = None
            modified_file = parsed.get("modified_file", {})
            if isinstance(modified_file, dict):
                modified_name = str(modified_file.get("name") or requested_filename or "modified_file.txt")
                modified_content = str(modified_file.get("content") or "")
                if modified_content.strip():
                    artifact = save_code_edit_artifact(user_id, modified_name, modified_content)

            debug_code_edit_event(
                "code_edit_artifact",
                artifact_saved=bool(artifact),
                artifact_name=artifact.get("name", "") if artifact else "",
                artifact_path=artifact.get("saved_path", "") if artifact else "",
            )

            summary_text = format_code_edit_summary(parsed, artifact)

            for chunk in split_for_stream(summary_text):
                yield sse_chunk(req.model, content=chunk)

            yield sse_chunk(req.model, finish_reason="stop")
            yield "data: [DONE]\n\n"

            assistant_message: dict[str, Any] = {
                "role": "assistant",
                "content": summary_text,
                "qonduit_code_edit": {
                    "executive_summary": parsed["executive_summary"],
                    "change_summary": parsed["change_summary"],
                    "patch_confidence": parsed["patch_confidence"],
                },
            }

            if artifact is not None:
                assistant_message["qonduit_artifact"] = artifact

            state["summary"] = summary
            state["recent_messages"] = (trimmed_recent + [assistant_message])[-8:]
            state["last_model"] = req.model
            state["last_context_size"] = req.context_size
            state["last_prompt_tokens"] = prompt_tokens
            state["last_reserved_output"] = budget.reserved_output
            save_conversation(req.conversation_id, state)
            return

        assistant_text_parts = []

        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream("POST", f"{LLAMA_BASE}/v1/chat/completions", json=payload) as r:
                if r.status_code >= 400:
                    body = await r.aread()
                    raise HTTPException(status_code=r.status_code, detail=body.decode("utf-8", errors="ignore"))

                async for line in r.aiter_lines():
                    if not line:
                        continue
                    yield line + "\n\n"

                    if line.startswith("data: "):
                        raw = line[6:].strip()
                        if raw == "[DONE]":
                            continue
                        try:
                            obj = json.loads(raw)
                            delta = (
                                obj.get("choices", [{}])[0]
                                .get("delta", {})
                                .get("content")
                            )
                            if delta:
                                assistant_text_parts.append(delta)
                        except Exception:
                            pass

        assistant_message = {
            "role": "assistant",
            "content": "".join(assistant_text_parts),
        }

        state["summary"] = summary
        state["recent_messages"] = (trimmed_recent + [assistant_message])[-8:]
        state["last_model"] = req.model
        state["last_context_size"] = req.context_size
        state["last_prompt_tokens"] = prompt_tokens
        state["last_reserved_output"] = budget.reserved_output
        save_conversation(req.conversation_id, state)

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        },
    )

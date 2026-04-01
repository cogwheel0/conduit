from __future__ import annotations

import json
from pathlib import Path
from typing import Any

DATA_DIR = Path("/app/data/conversations")
DATA_DIR.mkdir(parents=True, exist_ok=True)


def _conv_path(conversation_id: str) -> Path:
    safe_id = "".join(c for c in conversation_id if c.isalnum() or c in ("-", "_"))
    if not safe_id:
        safe_id = "default"
    return DATA_DIR / f"{safe_id}.json"


def load_conversation(conversation_id: str) -> dict[str, Any]:
    path = _conv_path(conversation_id)
    if not path.exists():
        return {
            "conversation_id": conversation_id,
            "summary": "",
            "recent_messages": [],
            "last_model": None,
            "last_context_size": None,
        }
    return json.loads(path.read_text(encoding="utf-8"))


def save_conversation(conversation_id: str, payload: dict[str, Any]) -> None:
    path = _conv_path(conversation_id)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

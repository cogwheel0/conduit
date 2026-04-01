from __future__ import annotations

import httpx

LLAMA_BASE = "http://192.168.5.5:8080"


async def summarize_messages(
    model: str,
    existing_summary: str,
    older_messages: list[dict],
) -> str:
    if not older_messages:
        return existing_summary

    older_text = "\n".join(
        f"{m.get('role', 'user')}: {m.get('content', '')}"
        for m in older_messages
    )

    prompt = (
        "Update the rolling conversation summary.\n\n"
        "Keep important user preferences, active projects, unresolved questions, "
        "constraints, and concrete facts. Be concise but useful.\n\n"
        f"Existing summary:\n{existing_summary or '(none)'}\n\n"
        f"Older messages:\n{older_text}\n"
    )

    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "You compress conversations into concise working memory."
            },
            {
                "role": "user",
                "content": prompt
            },
        ],
        "max_tokens": 400,
        "temperature": 0.2,
    }

    async with httpx.AsyncClient(timeout=180.0) as client:
        r = await client.post(f"{LLAMA_BASE}/v1/chat/completions", json=payload)
        r.raise_for_status()
        data = r.json()
        return data["choices"][0]["message"]["content"].strip()

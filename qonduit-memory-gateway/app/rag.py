from __future__ import annotations

import uuid
import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct, Filter, FieldCondition, MatchValue

QDRANT_URL = "http://192.168.5.5:6333"
EMBED_BASE = "http://192.168.5.5:8082"

COLLECTION_NAME = "qonduit_rag"
VECTOR_SIZE = 384  # all-MiniLM-L6-v2 embeddings are 384-dimensional

qdrant = QdrantClient(url=QDRANT_URL)


def _normalize_user_id(user_id: str | None) -> str:
    raw = (user_id or "default").strip().lower()
    safe = "".join(c for c in raw if c.isalnum() or c in ("-", "_"))
    return safe or "default"


def ensure_collection() -> None:
    try:
        qdrant.get_collection(COLLECTION_NAME)
    except Exception:
        qdrant.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(
                size=VECTOR_SIZE,
                distance=Distance.COSINE,
            ),
        )


async def embed_text(text: str) -> list[float]:
    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            f"{EMBED_BASE}/v1/embeddings",
            json={"input": text},
        )
        response.raise_for_status()
        data = response.json()
        return data["data"][0]["embedding"]


async def add_document(
    text: str,
    metadata: dict | None = None,
    point_id: str | None = None,
    user_id: str | None = None,
) -> str:
    if metadata is None:
        metadata = {}

    normalized_user = _normalize_user_id(user_id)
    vector = await embed_text(text)
    doc_id = point_id or str(uuid.uuid4())

    qdrant.upsert(
        collection_name=COLLECTION_NAME,
        points=[
            PointStruct(
                id=doc_id,
                vector=vector,
                payload={
                    "text": text,
                    "user_id": normalized_user,
                    **metadata,
                },
            )
        ],
    )

    return doc_id


async def search_documents(
    query: str,
    limit: int = 4,
    collection: str | None = None,
    user_id: str | None = None,
) -> list[dict]:
    vector = await embed_text(query)

    must_conditions = [
        FieldCondition(
            key="user_id",
            match=MatchValue(value=_normalize_user_id(user_id)),
        )
    ]

    if collection and collection.strip():
        must_conditions.append(
            FieldCondition(
                key="collection",
                match=MatchValue(value=collection.strip()),
            )
        )

    hits = qdrant.search(
        collection_name=COLLECTION_NAME,
        query_vector=vector,
        query_filter=Filter(must=must_conditions),
        limit=limit,
    )

    results = []
    for hit in hits:
        payload = hit.payload or {}
        results.append(
            {
                "id": str(hit.id),
                "score": hit.score,
                "text": payload.get("text", ""),
                "payload": payload,
            }
        )

    return results


def list_collections(user_id: str | None = None) -> list[str]:
    hits, _ = qdrant.scroll(
        collection_name=COLLECTION_NAME,
        scroll_filter=Filter(
            must=[
                FieldCondition(
                    key="source",
                    match=MatchValue(value="collection_marker"),
                ),
                FieldCondition(
                    key="user_id",
                    match=MatchValue(value=_normalize_user_id(user_id)),
                ),
            ]
        ),
        limit=1000,
        with_payload=True,
        with_vectors=False,
    )

    names = []
    for hit in hits:
        payload = hit.payload or {}
        name = payload.get("collection")
        if isinstance(name, str) and name.strip():
            names.append(name)

    return sorted(set(names))


async def create_collection_marker(name: str, user_id: str | None = None) -> str:
    normalized = name.strip()
    if not normalized:
        raise ValueError("Collection name cannot be empty")

    normalized_user = _normalize_user_id(user_id)
    existing = list_collections(user_id=normalized_user)
    if normalized in existing:
        return normalized

    marker_text = f"Collection marker for {normalized}"

    await add_document(
        text=marker_text,
        metadata={
            "source": "collection_marker",
            "collection": normalized,
            "document_name": "__collection_marker__",
        },
        user_id=normalized_user,
    )

    return normalized

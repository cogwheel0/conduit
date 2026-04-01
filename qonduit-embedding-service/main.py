from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

app = FastAPI(title="Qonduit Embedding Service")

model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")


class EmbeddingRequest(BaseModel):
    input: str | list[str]


@app.get("/health")
async def health():
    return {"ok": True, "service": "qonduit-embedding-service"}


@app.post("/v1/embeddings")
async def embeddings(req: EmbeddingRequest):
    texts = req.input if isinstance(req.input, list) else [req.input]
    vectors = model.encode(texts, normalize_embeddings=True).tolist()

    return {
        "object": "list",
        "data": [
            {
                "object": "embedding",
                "embedding": vector,
                "index": i,
            }
            for i, vector in enumerate(vectors)
        ],
        "model": "all-MiniLM-L6-v2",
    }

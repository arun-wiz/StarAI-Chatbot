import os
from typing import List, Dict, Any
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from pymongo import MongoClient
from bson.decimal128 import Decimal128

# Config: MONGO_URI comes from Secret, others from ConfigMap
MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
MONGO_DB = os.getenv("MONGO_DB", "stardb")
MONGO_COLLECTION = os.getenv("MONGO_COLLECTION", "services")
LANGFLOW_URL = os.getenv("LANGFLOW_URL", "http://127.0.0.1:7860")
FLOW_ID = os.getenv("FLOW_ID", "REPLACE_WITH_YOUR_FLOW_ID")

client = MongoClient(MONGO_URI)
services_col = client[MONGO_DB][MONGO_COLLECTION]

app = FastAPI(title="Langflow Chatbot (sidecar, Mongo-backed)", version="1.0.0")

class ChatRequest(BaseModel):
    message: str = Field(..., description="User message")
    top_k: int = Field(3, ge=1, le=20, description="How many services to include as context")

class Service(BaseModel):
    name: str
    subscribers: int
    revenue: str  # Decimal128 rendered as string

class ChatResponse(BaseModel):
    answer: str
    context: List[Service]

def _to_service_doc(doc: Dict[str, Any]) -> Service:
    revenue = doc.get("revenue")
    if isinstance(revenue, Decimal128):
        revenue = str(revenue.to_decimal())
    else:
        revenue = str(revenue)
    return Service(
        name=doc.get("name"),
        subscribers=int(doc.get("subscribers", 0)),
        revenue=revenue
    )

@app.get("/health")
def health():
    try:
        services_col.estimated_document_count()
    except Exception as e:
        return {"ok": False, "error": f"Mongo error: {e}"}
    return {"ok": True}

@app.get("/api/services", response_model=List[Service])
def list_services():
    docs = list(services_col.find({}, {"_id": 0, "name": 1, "subscribers": 1, "revenue": 1}).sort("name", 1))
    return [_to_service_doc(d) for d in docs]

@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    docs = list(
        services_col.find({}, {"_id": 0, "name": 1, "subscribers": 1, "revenue": 1})
                    .sort("subscribers", -1)
                    .limit(req.top_k)
    )
    context = [_to_service_doc(d) for d in docs]
    context_str = "\n".join([f"{s.name}: subscribers={s.subscribers}, revenue={s.revenue}" for s in context])

    payload = {
        "input_value": req.message,
        "input_type": "chat",
        "output_type": "chat",
        "tweaks": { "context": context_str }
    }

    url = f"{LANGFLOW_URL}/api/v1/run/{FLOW_ID}?stream=false"
    async with httpx.AsyncClient(timeout=60.0) as http:
        r = await http.post(url, json=payload)
        if r.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"Langflow error: {r.text}")
        data = r.json()

    try:
        answer = data["outputs"][0]["outputs"][0]["results"]["message"]["text"]
    except Exception:
        answer = str(data)

    return ChatResponse(answer=answer, context=context)

# Public pass-through for /api/v1/validate/code (no auth per your requirement)
class ValidateCodeRequest(BaseModel):
    code: str

@app.post("/api/v1/validate/code")
async def validate_code(req: ValidateCodeRequest):
    url = f"{LANGFLOW_URL}/api/v1/validate/code"
    async with httpx.AsyncClient(timeout=30.0) as http:
        r = await http.post(url, json=req.model_dump())
        return r.json(), r.status_code

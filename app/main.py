import os
from typing import List, Dict, Any
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
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


@app.get("/", response_class=HTMLResponse)
def chat_ui():
    return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>StarAI Chat</title>
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <style>
    body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
    .msg { padding: .75rem 1rem; border-radius: 10px; margin: .5rem 0; }
    .user { background: #eef; align-self: flex-end; }
    .bot  { background: #f5f5f5; }
    #log  { display: flex; flex-direction: column; gap: .25rem; }
    button { padding: .5rem 1rem; }
  </style>
</head>
<body>
  <h1>StarAI Chat</h1>
  <p>Ask a question. The bot will consult MongoDB (<code>stardb.services</code>) for context.</p>
  <div id="log"></div>
  <form id="f">
    <input id="q" placeholder="Type your question…" style="width:70%" />
    <input id="k" type="number" min="1" max="20" value="3" style="width:4rem" />
    <button type="submit">Send</button>
  </form>
<script>
const log = document.getElementById('log');
const form = document.getElementById('f');
const q = document.getElementById('q');
const k = document.getElementById('k');

function add(role, text){
  const div = document.createElement('div');
  div.className = 'msg ' + (role === 'user' ? 'user' : 'bot');
  div.textContent = text;
  log.appendChild(div);
  window.scrollTo(0, document.body.scrollHeight);
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const message = q.value.trim();
  if(!message) return;
  add('user', message);
  q.value = '';
  try {
    const r = await fetch('/chat', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ message, top_k: parseInt(k.value||'3',10) })
    });
    const data = await r.json();
    if(!r.ok) throw new Error(JSON.stringify(data));
    add('bot', data.answer);
  } catch (err) {
    add('bot', 'Error: ' + err.message);
  }
});
</script>
</body>
</html>
    """
    url = f"{LANGFLOW_URL}/api/v1/validate/code"
    async with httpx.AsyncClient(timeout=30.0) as http:
        r = await http.post(url, json=req.model_dump())
        return r.json(), r.status_code

import os
from typing import List, Dict, Any, Literal

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from pymongo import MongoClient
from bson.decimal128 import Decimal128

# ========= Config from env (K8s ConfigMap/Secret) =========
MONGO_URI        = os.getenv("MONGO_URI", "mongodb://localhost:27017")
MONGO_DB         = os.getenv("MONGO_DB", "stardb")
MONGO_COLLECTION = os.getenv("MONGO_COLLECTION", "services")
LANGFLOW_URL     = os.getenv("LANGFLOW_URL", "http://127.0.0.1:7860")
FLOW_ID          = os.getenv("FLOW_ID", "REPLACE_WITH_YOUR_FLOW_ID")

# Optional model overrides (set in ConfigMap if you want)
LLM_NODE_ID = os.getenv("LLM_NODE_ID")       # e.g., "ChatOpenAI-abc123" from Langflow UI
MODEL_NAME  = os.getenv("MODEL_NAME")        # e.g., "gpt-4o-mini"
MAX_TOKENS  = os.getenv("MAX_TOKENS")        # e.g., "256"
TEMPERATURE = os.getenv("TEMPERATURE")       # e.g., "0"

# ========= Mongo client =========
client = MongoClient(
    MONGO_URI,
    serverSelectionTimeoutMS=2000,
    connectTimeoutMS=2000,
    socketTimeoutMS=2000,
)
services_col = client[MONGO_DB][MONGO_COLLECTION]

# ========= FastAPI =========
app = FastAPI(title="Langflow Chatbot (Mongo-grounded)", version="1.1.0")


# -------------------- Models --------------------
class ChatRequest(BaseModel):
    message: str = Field(..., description="User message")
    top_k: int = Field(3, ge=1, le=20, description="How many services to include as context")
    sort_by: Literal["revenue", "subscribers"] = Field(
        "revenue", description="Sort context by this field (desc)"
    )


class Service(BaseModel):
    name: str
    subscribers: int
    revenue: str  # Decimal128 rendered as string


class ChatResponse(BaseModel):
    answer: str
    context: List[Service]


# -------------------- Helpers --------------------
def _to_service(doc: Dict[str, Any]) -> Service:
    revenue = doc.get("revenue")
    if isinstance(revenue, Decimal128):
        revenue = str(revenue.to_decimal())
    else:
        revenue = str(revenue)
    return Service(
        name=str(doc.get("name")),
        subscribers=int(doc.get("subscribers", 0)),
        revenue=revenue,
    )


def _build_context(services: List[Service]) -> str:
    """
    Pipe-delimited rows to make grounding unambiguous.
    Example line:
    StarCloud|subscribers=15000|revenue=112000.00
    """
    return "\n".join(
        f"{s.name}|subscribers={s.subscribers}|revenue={s.revenue}" for s in services
    )


def _model_tweaks(context_str: str) -> Dict[str, Any]:
    tweaks: Dict[str, Any] = {"context": context_str}
    if LLM_NODE_ID:
        overrides: Dict[str, Any] = {}
        if MODEL_NAME:
            overrides["model_name"] = MODEL_NAME
        if MAX_TOKENS:
            try:
                overrides["max_tokens"] = int(MAX_TOKENS)
            except ValueError:
                pass
        if TEMPERATURE:
            try:
                overrides["temperature"] = float(TEMPERATURE)
            except ValueError:
                pass
        if overrides:
            tweaks[LLM_NODE_ID] = overrides
    return tweaks


# -------------------- Health & Data --------------------
@app.get("/health")
def health():
    return {"ok": True}


@app.get("/health/deps")
def health_deps():
    try:
        services_col.estimated_document_count()
    except Exception as e:
        return {"ok": False, "mongo_ok": False, "error": f"Mongo error: {e}"}
    return {"ok": True, "mongo_ok": True}


@app.get("/api/services", response_model=List[Service])
def list_services():
    docs = list(
        services_col.find({}, {"_id": 0, "name": 1, "subscribers": 1, "revenue": 1}).sort("name", 1)
    )
    return [_to_service(d) for d in docs]


# -------------------- Chat --------------------
@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    q_lower = req.message.lower().strip()

    projection = {"_id": 0, "name": 1, "subscribers": 1, "revenue": 1}
    docs: List[Dict[str, Any]] = []

    # Intent: "highest" / "most" revenue
    if ("highest" in q_lower or "most" in q_lower) and "revenue" in q_lower:
        docs = list(services_col.find({}, projection).sort("revenue", -1).limit(1))

    # Intent: "highest" / "most" subscribers
    elif ("highest" in q_lower or "most" in q_lower) and (
        "subscriber" in q_lower or "users" in q_lower
    ):
        docs = list(services_col.find({}, projection).sort("subscribers", -1).limit(1))

    # Search: try to match service name from the question
    else:
        # Use longer tokens first to reduce false positives
        tokens = sorted({t for t in req.message.split() if len(t) >= 4}, key=len, reverse=True)
        for t in tokens:
            # Case-insensitive substring match on 'name'
            docs = list(
                services_col.find(
                    {"name": {"$regex": t, "$options": "i"}},
                    projection,
                ).limit(req.top_k)
            )
            if docs:
                break

        # Fallback: previous behavior (top_k sorted)
        if not docs:
            sort_field = "revenue" if req.sort_by == "revenue" else "subscribers"
            docs = list(services_col.find({}, projection).sort(sort_field, -1).limit(req.top_k))

    context = [_to_service(d) for d in docs]
    context_str = _build_context(context)

    # Strong grounding wrapper: force the LLM to use only the provided dataset
    grounded_message = (
        "Using ONLY the dataset lines below (pipe-delimited), answer the question.\n"
        "If the answer cannot be derived exactly, reply: Not in dataset.\n\n"
        f"DATASET:\n{context_str}\n\n"
        f"QUESTION: {req.message}\n"
        "Return a concise answer and cite the exact service name(s) from the dataset if applicable."
    )

    payload = {
        "input_value": grounded_message,   # goes to the flow's chat input
        "input_type": "chat",
        "output_type": "chat",
        "tweaks": _model_tweaks(context_str),  # still send 'context' for your Prompt node {{context}}
    }

    url = f"{LANGFLOW_URL}/api/v1/run/{FLOW_ID}?stream=false"
    async with httpx.AsyncClient(timeout=60.0) as http:
        r = await http.post(url, json=payload)
        if r.status_code >= 400:
            # Try to soften well-known provider errors (e.g., 429 insufficient_quota)
            try:
                jd = r.json()
                detail = jd.get("detail") if isinstance(jd, dict) else None
                if detail and "insufficient_quota" in str(detail):
                    raise HTTPException(
                        status_code=503,
                        detail="LLM provider reports insufficient quota. Try again later or use a key/provider with credits.",
                    )
            except Exception:
                pass
            raise HTTPException(status_code=502, detail=f"Langflow error: {r.text}")

        data = r.json()

    # Extract first message text; if structure differs, return the raw object for debugging
    try:
        answer = data["outputs"][0]["outputs"][0]["results"]["message"]["text"]
    except Exception:
        answer = str(data)

    return ChatResponse(answer=answer, context=context)


# -------------------- Pass-through to Langflow's validator --------------------
class ValidateCodeRequest(BaseModel):
    code: str


@app.post("/api/v1/validate/code")
async def validate_code(req: ValidateCodeRequest):
    url = f"{LANGFLOW_URL}/api/v1/validate/code"
    async with httpx.AsyncClient(timeout=30.0) as http:
        r = await http.post(url, json=req.model_dump())
        return r.json(), r.status_code


# -------------------- Minimal browser chat UI (GET /) --------------------
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
    form { margin-top: 1rem; display: flex; gap: .5rem; }
    input[type="text"] { flex: 1; }
    small { color: #666; }
  </style>
</head>
<body>
  <h1>StarAI Chat</h1>
  <p>Grounded on MongoDB (<code>stardb.services</code>). Default context sorts by <b>revenue</b> desc.</p>
  <div id="log"></div>
  <form id="f" onsubmit="return false;">
    <input id="q" type="text" placeholder="Type your question…" />
    <label>top_k <input id="k" type="number" min="1" max="20" value="3" style="width:4rem" /></label>
    <label>sort_by
      <select id="sb">
        <option value="revenue" selected>revenue</option>
        <option value="subscribers">subscribers</option>
      </select>
    </label>
    <button id="send">Send</button>
  </form>
  <p><small>Tip: ask “Which service has the highest revenue?”</small></p>
<script>
const log = document.getElementById('log');
const q   = document.getElementById('q');
const k   = document.getElementById('k');
const sb  = document.getElementById('sb');
const send= document.getElementById('send');

function add(role, text){
  const div = document.createElement('div');
  div.className = 'msg ' + (role === 'user' ? 'user' : 'bot');
  div.textContent = text;
  log.appendChild(div);
  window.scrollTo(0, document.body.scrollHeight);
}

send.addEventListener('click', async () => {
  const message = q.value.trim();
  if(!message) return;
  add('user', message);
  q.value = '';
  try {
    const r = await fetch('/chat', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({
        message,
        top_k: parseInt(k.value || '3', 10),
        sort_by: sb.value
      })
    });
    const data = await r.json();
    if(!r.ok) throw new Error(data.detail || JSON.stringify(data));
    add('bot', data.answer);
  } catch (err) {
    add('bot', 'Error: ' + err.message);
  }
});
</script>
</body>
</html>
    """

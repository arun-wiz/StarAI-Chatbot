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
    try:
        q_lower = req.message.lower().strip()

        # ----- Build context from Mongo (optional; allow empty context if Mongo fails) -----
        projection = {"_id": 0, "name": 1, "subscribers": 1, "revenue": 1}
        docs: List[Dict[str, Any]] = []
        try:
            sort_field = "revenue" if req.sort_by == "revenue" else "subscribers"
            docs = list(services_col.find({}, projection).sort(sort_field, -1))
        except Exception:
            docs = []

        context = [_to_service(d) for d in docs]
        context_str = _build_context(context)

        grounded_message = (
            "Using ONLY the dataset lines below (pipe-delimited), answer the question.\n"
            "If the answer cannot be derived exactly, reply: Not in dataset.\n\n"
            f"DATASET:\n{context_str}\n\n"
            f"QUESTION: {req.message}\n"
            "Return a concise answer and cite the exact service name(s) from the dataset if applicable."
        )

        payload = {
            "input_value": grounded_message,
            "input_type": "chat",
            "output_type": "chat",
            "tweaks": _model_tweaks(context_str),
        }

        # ----- Call Langflow -----
        url = f"{LANGFLOW_URL}/api/v1/run/{FLOW_ID}?stream=false"
        async with httpx.AsyncClient(timeout=60.0) as http:
            r = await http.post(url, json=payload)

        if r.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"Langflow error: {r.text}")

        content_type = (r.headers.get("content-type") or "").lower()
        try:
            data = r.json()
        except Exception:
            snippet = r.text[:500]
            raise HTTPException(
                status_code=502,
                detail=(
                    "Langflow returned a non-JSON response. "
                    f"status={r.status_code} content-type={content_type} body_snippet={snippet!r}"
                ),
            )

        try:
            answer = data["outputs"][0]["outputs"][0]["results"]["message"]["text"]
        except Exception:
            answer = str(data)

        return ChatResponse(answer=answer, context=context)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Gateway error: {type(e).__name__}: {e}")


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
    :root {
      --bg: #0b1220;
      --card: rgba(255, 255, 255, 0.06);
      --card2: rgba(255, 255, 255, 0.08);
      --text: rgba(255, 255, 255, 0.92);
      --muted: rgba(255, 255, 255, 0.65);
      --stroke: rgba(255, 255, 255, 0.14);
      --user: rgba(99, 102, 241, 0.35);
      --bot: rgba(255, 255, 255, 0.08);
      --accent: #7c3aed;
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial;
      color: var(--text);
      background:
        radial-gradient(1200px 800px at 20% 10%, rgba(124, 58, 237, 0.25), transparent 60%),
        radial-gradient(900px 600px at 80% 0%, rgba(59, 130, 246, 0.22), transparent 55%),
        var(--bg);
    }
    .wrap { max-width: 920px; margin: 0 auto; padding: 24px 16px 28px; }
    .header {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 16px;
      padding: 10px 2px 16px;
    }
    .title { font-size: 20px; font-weight: 700; letter-spacing: 0.2px; }
    .subtitle { font-size: 13px; color: var(--muted); }
    .card {
      border: 1px solid var(--stroke);
      background: linear-gradient(180deg, var(--card), rgba(255, 255, 255, 0.04));
      border-radius: 16px;
      overflow: hidden;
      box-shadow: 0 20px 60px rgba(0,0,0,0.45);
    }
    .log {
      height: min(70vh, 560px);
      padding: 18px 16px;
      overflow: auto;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .msg {
      max-width: 85%;
      padding: 10px 12px;
      border-radius: 14px;
      border: 1px solid var(--stroke);
      background: var(--bot);
      white-space: pre-wrap;
      line-height: 1.35;
    }
    .msg.user {
      margin-left: auto;
      background: var(--user);
      border-color: rgba(99, 102, 241, 0.55);
    }
    .msg.bot { margin-right: auto; }
    .meta {
      padding: 10px 14px;
      border-top: 1px solid var(--stroke);
      background: linear-gradient(180deg, rgba(255, 255, 255, 0.06), rgba(255, 255, 255, 0.04));
      display: flex;
      gap: 10px;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
    }
    .controls { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    label { font-size: 12px; color: var(--muted); display: flex; align-items: center; gap: 8px; }
    select {
      appearance: none;
      background: var(--card2);
      border: 1px solid var(--stroke);
      color: var(--text);
      padding: 8px 10px;
      border-radius: 10px;
      outline: none;
    }
    .composer {
      display: flex;
      gap: 10px;
      align-items: center;
      flex: 1;
      min-width: 280px;
    }
    input[type="text"] {
      flex: 1;
      padding: 10px 12px;
      border-radius: 12px;
      border: 1px solid var(--stroke);
      background: rgba(255, 255, 255, 0.06);
      color: var(--text);
      outline: none;
    }
    input[type="text"]::placeholder { color: rgba(255, 255, 255, 0.45); }
    button {
      padding: 10px 12px;
      border-radius: 12px;
      border: 1px solid rgba(124, 58, 237, 0.45);
      background: linear-gradient(180deg, rgba(124,58,237,0.95), rgba(99,102,241,0.85));
      color: white;
      font-weight: 650;
      cursor: pointer;
    }
    button:disabled { opacity: 0.6; cursor: not-allowed; }
    .hint { font-size: 12px; color: var(--muted); }
    .pill {
      font-size: 12px;
      color: var(--muted);
      border: 1px solid var(--stroke);
      background: rgba(255, 255, 255, 0.05);
      padding: 6px 10px;
      border-radius: 999px;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="header">
      <div>
        <div class="title">StarAI Chat</div>
        <div class="subtitle">Grounded on MongoDB (<code>stardb.services</code>). Context sorted by <b>revenue</b> or <b>subscribers</b>.</div>
      </div>
      <div class="pill">Demo UI</div>
    </div>

    <div class="card">
      <div id="log" class="log"></div>
      <div class="meta">
        <div class="controls">
          <label>sort_by
            <select id="sb">
              <option value="revenue" selected>revenue</option>
              <option value="subscribers">subscribers</option>
            </select>
          </label>
          <div class="hint">Tip: ask “Which service has the highest revenue?”</div>
        </div>

        <form id="f" class="composer" onsubmit="return false;">
          <input id="q" type="text" autocomplete="off" placeholder="Ask about services, revenue, subscribers…" />
          <button id="send">Send</button>
        </form>
      </div>
    </div>
  </div>
<script>
const log  = document.getElementById('log');
const q    = document.getElementById('q');
const sb   = document.getElementById('sb');
const send = document.getElementById('send');

function scrollToBottom(){
  log.scrollTop = log.scrollHeight;
}

function add(role, text){
  const div = document.createElement('div');
  div.className = 'msg ' + (role === 'user' ? 'user' : 'bot');
  div.textContent = text;
  log.appendChild(div);
  scrollToBottom();
  return div;
}

async function submit(){
  const message = q.value.trim();
  if(!message) return;

  add('user', message);
  q.value = '';
  q.focus();
  send.disabled = true;

  const pending = add('bot', 'Thinking…');
  try {
    const r = await fetch('/chat', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({
        message,
        sort_by: sb.value
      })
    });

    const data = await r.json();
    if(!r.ok) throw new Error(data.detail || JSON.stringify(data));
    pending.textContent = data.answer;
  } catch (err) {
    pending.textContent = 'Error: ' + err.message;
  } finally {
    send.disabled = false;
    scrollToBottom();
  }
}

send.addEventListener('click', submit);
q.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    submit();
  }
});

add('bot', 'Hi! Ask a question about the services dataset.');
</script>
</body>
</html>
    """

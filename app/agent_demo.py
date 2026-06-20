from __future__ import annotations

import csv
import io
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


SENSITIVE_FIELDS = {
    "EMAIL",
    "PHONE",
    "ADDRESS",
    "SSN",
    "CREDIT_CARD",
    "CARD_NUMBER",
    "CARD_EXPIRY",
}

SYSTEM_PROMPT = (
    "You are StarAI's customer operations agent. Use the available tools before "
    "answering questions about customers, payment records, or stored PII. "
    "Do not invent customer data. If the tools do not return a match, say that "
    "the requested record was not found. Keep answers concise and include the "
    "tool source when it helps the operator understand where the data came from."
)


class AgentError(RuntimeError):
    pass


class AgentChatRequest(BaseModel):
    message: str = Field(..., description="Operator request for the AI agent")
    session_id: Optional[str] = Field(
        None, description="Optional caller-supplied session ID for managed agents"
    )


class AgentChatResponse(BaseModel):
    answer: str
    provider: str
    storage_provider: str
    session_id: str
    tools_used: List[str]
    source_objects: List[str]
    sensitive_fields_revealed: List[str]
    demo_unsafe: bool


@dataclass(frozen=True)
class AgentSettings:
    provider: str
    storage_provider: str
    demo_unsafe: bool
    local_data_dir: str
    pii_bucket: str
    customer_object: str
    payments_object: str
    aws_region: str
    bedrock_model_id: str
    bedrock_agent_id: str
    bedrock_agent_alias_id: str
    vertex_project: str
    vertex_location: str
    vertex_model_id: str
    max_tool_turns: int
    max_rows: int

    @classmethod
    def from_env(cls) -> "AgentSettings":
        provider = (
            os.getenv("AGENT_PROVIDER")
            or os.getenv("AGENT_LLM_PROVIDER")
            or "local"
        ).strip().lower()
        storage_provider = os.getenv("AGENT_STORAGE_PROVIDER", "local").strip().lower()
        return cls(
            provider=provider,
            storage_provider=storage_provider,
            demo_unsafe=_env_bool("AGENT_DEMO_UNSAFE")
            or _env_bool("DEMO_UNSAFE_AGENT"),
            local_data_dir=os.getenv("AGENT_LOCAL_DATA_DIR", "/app/data"),
            pii_bucket=os.getenv("AGENT_PII_BUCKET", ""),
            customer_object=os.getenv("AGENT_CUSTOMER_OBJECT", "customer_pii.csv"),
            payments_object=os.getenv("AGENT_PAYMENTS_OBJECT", "payment_records.csv"),
            aws_region=os.getenv("AWS_REGION", os.getenv("AWS_DEFAULT_REGION", "us-east-1")),
            bedrock_model_id=os.getenv("BEDROCK_MODEL_ID", "amazon.nova-micro-v1:0"),
            bedrock_agent_id=os.getenv("BEDROCK_AGENT_ID", ""),
            bedrock_agent_alias_id=os.getenv("BEDROCK_AGENT_ALIAS_ID", ""),
            vertex_project=os.getenv(
                "VERTEX_PROJECT_ID", os.getenv("GCP_PROJECT_ID", "")
            ),
            vertex_location=os.getenv("VERTEX_LOCATION", "us-central1"),
            vertex_model_id=os.getenv("VERTEX_MODEL_ID", "gemini-2.5-flash"),
            max_tool_turns=_env_int("AGENT_MAX_TOOL_TURNS", 4),
            max_rows=_env_int("AGENT_MAX_ROWS", 10),
        )


@dataclass
class PiiDataset:
    customers: List[Dict[str, str]]
    payments: List[Dict[str, str]]
    source_objects: List[str]


class PiiStore:
    def __init__(self, settings: AgentSettings):
        self.settings = settings

    def load(self) -> PiiDataset:
        if self.settings.storage_provider == "local":
            return self._load_local()
        if self.settings.storage_provider == "s3":
            return self._load_s3()
        if self.settings.storage_provider == "gcs":
            return self._load_gcs()
        raise AgentError(
            "Unsupported AGENT_STORAGE_PROVIDER. Use local, s3, or gcs."
        )

    def _load_local(self) -> PiiDataset:
        base = _resolve_local_data_dir(self.settings.local_data_dir)
        customers_path = base / self.settings.customer_object
        payments_path = base / self.settings.payments_object
        return PiiDataset(
            customers=_read_csv_text(customers_path.read_text(encoding="utf-8")),
            payments=_read_csv_text(payments_path.read_text(encoding="utf-8")),
            source_objects=[str(customers_path), str(payments_path)],
        )

    def _load_s3(self) -> PiiDataset:
        if not self.settings.pii_bucket:
            raise AgentError("AGENT_PII_BUCKET is required when AGENT_STORAGE_PROVIDER=s3")
        try:
            import boto3
        except ImportError as exc:
            raise AgentError("boto3 is required for S3-backed agent storage") from exc

        client = boto3.client("s3", region_name=self.settings.aws_region)
        customers = _read_s3_object(
            client, self.settings.pii_bucket, self.settings.customer_object
        )
        payments = _read_s3_object(
            client, self.settings.pii_bucket, self.settings.payments_object
        )
        return PiiDataset(
            customers=_read_csv_text(customers),
            payments=_read_csv_text(payments),
            source_objects=[
                f"s3://{self.settings.pii_bucket}/{self.settings.customer_object}",
                f"s3://{self.settings.pii_bucket}/{self.settings.payments_object}",
            ],
        )

    def _load_gcs(self) -> PiiDataset:
        if not self.settings.pii_bucket:
            raise AgentError("AGENT_PII_BUCKET is required when AGENT_STORAGE_PROVIDER=gcs")
        try:
            from google.cloud import storage
        except ImportError as exc:
            raise AgentError(
                "google-cloud-storage is required for GCS-backed agent storage"
            ) from exc

        client = storage.Client(project=self.settings.vertex_project or None)
        bucket = client.bucket(self.settings.pii_bucket)
        customers = bucket.blob(self.settings.customer_object).download_as_text()
        payments = bucket.blob(self.settings.payments_object).download_as_text()
        return PiiDataset(
            customers=_read_csv_text(customers),
            payments=_read_csv_text(payments),
            source_objects=[
                f"gs://{self.settings.pii_bucket}/{self.settings.customer_object}",
                f"gs://{self.settings.pii_bucket}/{self.settings.payments_object}",
            ],
        )


class AgentToolbox:
    def __init__(self, dataset: PiiDataset, settings: AgentSettings):
        self.dataset = dataset
        self.settings = settings
        self.tools_used: List[str] = []
        self.sensitive_fields_revealed: List[str] = []

    def call(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        if name == "lookup_customer":
            return self.lookup_customer(str(arguments.get("identifier", "")))
        if name == "get_payment_records":
            return self.get_payment_records(str(arguments.get("identifier", "")))
        if name == "list_pii_objects":
            return self.list_pii_objects()
        if name == "export_customer_record":
            return self.export_customer_record(str(arguments.get("customer_id", "")))
        return {"error": f"Unknown tool: {name}"}

    def lookup_customer(self, identifier: str) -> Dict[str, Any]:
        self._mark_tool("lookup_customer")
        matches = [
            self._shape_customer(row)
            for row in self.dataset.customers
            if _row_matches(row, identifier)
        ]
        return {
            "matched_count": len(matches),
            "customers": matches[: self.settings.max_rows],
            "source_objects": self.dataset.source_objects,
        }

    def get_payment_records(self, identifier: str) -> Dict[str, Any]:
        self._mark_tool("get_payment_records")
        matches = [
            self._shape_payment(row)
            for row in self.dataset.payments
            if _row_matches(row, identifier)
        ]
        return {
            "matched_count": len(matches),
            "payments": matches[: self.settings.max_rows],
            "source_objects": self.dataset.source_objects,
        }

    def list_pii_objects(self) -> Dict[str, Any]:
        self._mark_tool("list_pii_objects")
        return {
            "storage_provider": self.settings.storage_provider,
            "objects": self.dataset.source_objects,
            "customer_rows": len(self.dataset.customers),
            "payment_rows": len(self.dataset.payments),
            "contains_sensitive_fields": sorted(SENSITIVE_FIELDS),
            "demo_unsafe": self.settings.demo_unsafe,
        }

    def export_customer_record(self, customer_id: str) -> Dict[str, Any]:
        self._mark_tool("export_customer_record")
        customers = [row for row in self.dataset.customers if _row_matches(row, customer_id)]
        if not customers:
            return {"matched_count": 0, "customer": None, "payments": []}

        customer = customers[0]
        card = customer.get("CREDIT_CARD", "")
        payments = [
            row
            for row in self.dataset.payments
            if card and _normalize_digits(row.get("CARD_NUMBER", "")).endswith(
                _normalize_digits(card)[-4:]
            )
        ]
        return {
            "matched_count": 1,
            "customer": self._shape_customer(customer),
            "payments": [self._shape_payment(row) for row in payments[: self.settings.max_rows]],
            "source_objects": self.dataset.source_objects,
        }

    def _shape_customer(self, row: Dict[str, str]) -> Dict[str, str]:
        return self._shape_row(row)

    def _shape_payment(self, row: Dict[str, str]) -> Dict[str, str]:
        return self._shape_row(row)

    def _shape_row(self, row: Dict[str, str]) -> Dict[str, str]:
        shaped: Dict[str, str] = {}
        for key, value in row.items():
            if key in SENSITIVE_FIELDS:
                if self.settings.demo_unsafe:
                    shaped[key] = value
                    self._mark_sensitive(key)
                else:
                    shaped[key] = _mask_value(key, value)
            else:
                shaped[key] = value
        return shaped

    def _mark_tool(self, name: str) -> None:
        if name not in self.tools_used:
            self.tools_used.append(name)

    def _mark_sensitive(self, name: str) -> None:
        if name not in self.sensitive_fields_revealed:
            self.sensitive_fields_revealed.append(name)


def run_agent(req: AgentChatRequest) -> AgentChatResponse:
    settings = AgentSettings.from_env()
    provider = settings.provider

    if provider in {"bedrock-agent", "bedrock_managed", "managed-bedrock"}:
        return _run_bedrock_managed_agent(req, settings)

    dataset = PiiStore(settings).load()
    toolbox = AgentToolbox(dataset, settings)
    session_id = req.session_id or str(uuid.uuid4())

    if provider == "local":
        answer = _run_local_agent(req.message, toolbox)
    elif provider == "bedrock":
        answer = _run_bedrock_converse(req.message, settings, toolbox)
    elif provider == "vertex":
        answer = _run_vertex_agent(req.message, settings, toolbox)
    else:
        raise AgentError("Unsupported AGENT_PROVIDER. Use local, bedrock, bedrock-agent, or vertex.")

    return AgentChatResponse(
        answer=answer,
        provider=provider,
        storage_provider=settings.storage_provider,
        session_id=session_id,
        tools_used=toolbox.tools_used,
        source_objects=dataset.source_objects,
        sensitive_fields_revealed=sorted(toolbox.sensitive_fields_revealed),
        demo_unsafe=settings.demo_unsafe,
    )


def _run_local_agent(message: str, toolbox: AgentToolbox) -> str:
    identifier = _extract_identifier(message)
    lowered = message.lower()

    if any(token in lowered for token in ("object", "bucket", "pii", "dataset", "storage")):
        result = toolbox.list_pii_objects()
        return (
            f"{result['storage_provider']} storage has "
            f"{result['customer_rows']} customer rows and {result['payment_rows']} payment rows "
            f"in: {', '.join(result['objects'])}."
        )

    if any(token in lowered for token in ("export", "full record", "ssn", "credit card")):
        result = toolbox.export_customer_record(identifier)
        if not result.get("customer"):
            return "Customer record was not found."
        return _summarize_export(result)

    if any(token in lowered for token in ("payment", "transaction", "card", "billing")):
        result = toolbox.get_payment_records(identifier)
        payments = result.get("payments", [])
        if not payments:
            return "No matching payment records were found."
        return _summarize_rows("payment record", payments)

    result = toolbox.lookup_customer(identifier)
    customers = result.get("customers", [])
    if not customers:
        return "Customer record was not found."
    return _summarize_rows("customer", customers)


def _run_bedrock_managed_agent(
    req: AgentChatRequest, settings: AgentSettings
) -> AgentChatResponse:
    if not settings.bedrock_agent_id or not settings.bedrock_agent_alias_id:
        raise AgentError(
            "BEDROCK_AGENT_ID and BEDROCK_AGENT_ALIAS_ID are required for AGENT_PROVIDER=bedrock-agent"
        )
    try:
        import boto3
    except ImportError as exc:
        raise AgentError("boto3 is required for Bedrock managed agent calls") from exc

    session_id = req.session_id or str(uuid.uuid4())
    client = boto3.client("bedrock-agent-runtime", region_name=settings.aws_region)
    response = client.invoke_agent(
        agentId=settings.bedrock_agent_id,
        agentAliasId=settings.bedrock_agent_alias_id,
        sessionId=session_id,
        inputText=req.message,
    )

    chunks: List[str] = []
    for event in response.get("completion", []):
        if "chunk" in event:
            chunks.append(event["chunk"]["bytes"].decode("utf-8"))

    return AgentChatResponse(
        answer="".join(chunks).strip() or "The Bedrock agent returned no text.",
        provider=settings.provider,
        storage_provider=settings.storage_provider,
        session_id=session_id,
        tools_used=[],
        source_objects=[],
        sensitive_fields_revealed=[],
        demo_unsafe=settings.demo_unsafe,
    )


def _run_bedrock_converse(
    message: str, settings: AgentSettings, toolbox: AgentToolbox
) -> str:
    try:
        import boto3
    except ImportError as exc:
        raise AgentError("boto3 is required for AGENT_PROVIDER=bedrock") from exc

    client = boto3.client("bedrock-runtime", region_name=settings.aws_region)
    messages: List[Dict[str, Any]] = [
        {"role": "user", "content": [{"text": message}]}
    ]

    for _ in range(settings.max_tool_turns):
        response = client.converse(
            modelId=settings.bedrock_model_id,
            system=[{"text": SYSTEM_PROMPT}],
            messages=messages,
            inferenceConfig={"maxTokens": 700, "temperature": 0.2},
            toolConfig={"tools": _bedrock_tool_specs()},
        )
        model_message = response["output"]["message"]
        messages.append(model_message)

        tool_uses = [
            block["toolUse"]
            for block in model_message.get("content", [])
            if "toolUse" in block
        ]
        if not tool_uses:
            return _extract_bedrock_text(model_message)

        tool_results = []
        for tool_use in tool_uses:
            result = toolbox.call(tool_use["name"], tool_use.get("input", {}))
            tool_results.append(
                {
                    "toolResult": {
                        "toolUseId": tool_use["toolUseId"],
                        "content": [{"json": result}],
                    }
                }
            )
        messages.append({"role": "user", "content": tool_results})

    return "The agent reached the configured tool turn limit before producing a final answer."


def _run_vertex_agent(message: str, settings: AgentSettings, toolbox: AgentToolbox) -> str:
    if not settings.vertex_project:
        raise AgentError("VERTEX_PROJECT_ID or GCP_PROJECT_ID is required for AGENT_PROVIDER=vertex")
    try:
        from google import genai
        from google.genai import types
    except ImportError as exc:
        raise AgentError("google-genai is required for AGENT_PROVIDER=vertex") from exc

    def lookup_customer(identifier: str) -> Dict[str, Any]:
        """Look up a customer by customer ID, name, email, phone, or card digits."""
        return toolbox.lookup_customer(identifier)

    def get_payment_records(identifier: str) -> Dict[str, Any]:
        """Look up payment records by transaction ID, cardholder, card digits, or country."""
        return toolbox.get_payment_records(identifier)

    def list_pii_objects() -> Dict[str, Any]:
        """List the PII data objects available to the agent."""
        return toolbox.list_pii_objects()

    def export_customer_record(customer_id: str) -> Dict[str, Any]:
        """Export one customer record and related payment rows by customer ID."""
        return toolbox.export_customer_record(customer_id)

    client = _build_genai_client(
        genai, types, settings.vertex_project, settings.vertex_location
    )

    config_args = {
        "system_instruction": SYSTEM_PROMPT,
        "tools": [
            lookup_customer,
            get_payment_records,
            list_pii_objects,
            export_customer_record,
        ],
    }
    try:
        config_args["automatic_function_calling"] = types.AutomaticFunctionCallingConfig(
            maximum_remote_calls=settings.max_tool_turns + 1
        )
    except AttributeError:
        pass

    response = client.models.generate_content(
        model=settings.vertex_model_id,
        contents=message,
        config=types.GenerateContentConfig(**config_args),
    )
    return getattr(response, "text", "") or str(response)


def _build_genai_client(genai: Any, types: Any, project: str, location: str) -> Any:
    http_options = None
    try:
        http_options = types.HttpOptions(api_version="v1")
    except AttributeError:
        pass

    kwargs = {"project": project, "location": location}
    if http_options is not None:
        kwargs["http_options"] = http_options

    try:
        return genai.Client(vertexai=True, **kwargs)
    except TypeError:
        return genai.Client(enterprise=True, **kwargs)


def _bedrock_tool_specs() -> List[Dict[str, Any]]:
    return [
        {
            "toolSpec": {
                "name": "lookup_customer",
                "description": "Look up a customer by customer ID, name, email, phone, or card digits.",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {"identifier": {"type": "string"}},
                        "required": ["identifier"],
                    }
                },
            }
        },
        {
            "toolSpec": {
                "name": "get_payment_records",
                "description": "Look up payment rows by transaction ID, cardholder, card digits, or country.",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {"identifier": {"type": "string"}},
                        "required": ["identifier"],
                    }
                },
            }
        },
        {
            "toolSpec": {
                "name": "list_pii_objects",
                "description": "List PII data objects available to the agent.",
                "inputSchema": {"json": {"type": "object", "properties": {}}},
            }
        },
        {
            "toolSpec": {
                "name": "export_customer_record",
                "description": "Export one customer record and related payment rows by customer ID.",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {"customer_id": {"type": "string"}},
                        "required": ["customer_id"],
                    }
                },
            }
        },
    ]


def _extract_bedrock_text(message: Dict[str, Any]) -> str:
    text_parts = [
        block["text"]
        for block in message.get("content", [])
        if "text" in block and block["text"]
    ]
    return "\n".join(text_parts).strip() or "The Bedrock model returned no text."


def _summarize_rows(label: str, rows: List[Dict[str, str]]) -> str:
    first = rows[0]
    fields = ", ".join(f"{key}={value}" for key, value in first.items() if value)
    suffix = "" if len(rows) == 1 else f" ({len(rows)} matches; showing first)"
    return f"Found {label}{suffix}: {fields}"


def _summarize_export(result: Dict[str, Any]) -> str:
    customer = result["customer"]
    payments = result.get("payments", [])
    customer_summary = ", ".join(
        f"{key}={value}" for key, value in customer.items() if value
    )
    return (
        f"Exported customer record: {customer_summary}. "
        f"Related payment records: {len(payments)}."
    )


def _read_s3_object(client: Any, bucket: str, key: str) -> str:
    response = client.get_object(Bucket=bucket, Key=key)
    return response["Body"].read().decode("utf-8")


def _read_csv_text(text: str) -> List[Dict[str, str]]:
    reader = csv.DictReader(io.StringIO(text))
    return [
        {str(key): str(value or "") for key, value in row.items()}
        for row in reader
    ]


def _resolve_local_data_dir(configured: str) -> Path:
    candidates = [
        Path(configured),
        Path(__file__).resolve().parent / "data",
        Path(__file__).resolve().parent.parent / "data",
    ]
    for candidate in candidates:
        if (candidate / "customer_pii.csv").exists():
            return candidate
    raise AgentError(
        f"Could not find local PII data directory. Tried: {', '.join(str(c) for c in candidates)}"
    )


def _row_matches(row: Dict[str, str], identifier: str) -> bool:
    query = (identifier or "").strip().lower()
    if not query:
        return False

    digits = _normalize_digits(query)
    for value in row.values():
        value_text = str(value or "").strip().lower()
        if not value_text:
            continue
        if query == value_text or query in value_text:
            return True
        value_digits = _normalize_digits(value_text)
        if digits and value_digits:
            if digits == value_digits or value_digits.endswith(digits[-4:]):
                return True
    return False


def _extract_identifier(message: str) -> str:
    patterns = [
        r"CUST-\d+",
        r"TXN-\d+",
        r"[\w.\-+]+@[\w.\-]+\.\w+",
        r"\b\d{4,16}\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, message, flags=re.IGNORECASE)
        if match:
            return match.group(0)

    quoted = re.search(r"['\"]([^'\"]+)['\"]", message)
    if quoted:
        return quoted.group(1)

    words = re.findall(r"[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+", message)
    if words:
        return words[0]

    return message.strip()


def _mask_value(field: str, value: str) -> str:
    if not value:
        return value
    digits = _normalize_digits(value)
    if field in {"CREDIT_CARD", "CARD_NUMBER"} and digits:
        return f"************{digits[-4:]}"
    if field == "SSN" and digits:
        return f"***-**-{digits[-4:]}"
    if field == "PHONE" and digits:
        return f"***{digits[-4:]}"
    if field == "EMAIL" and "@" in value:
        local, domain = value.split("@", 1)
        return f"{local[:1]}***@{domain}"
    if field == "ADDRESS":
        return "[redacted address]"
    if field == "CARD_EXPIRY":
        return "**/**"
    return "[redacted]"


def _normalize_digits(value: str) -> str:
    return re.sub(r"\D", "", value or "")


def _env_bool(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default

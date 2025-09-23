FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && pip uninstall -y bson || true \
 && python - <<'PY'
import importlib, sys
for m in ("fastapi","uvicorn","httpx","pymongo"):
    importlib.import_module(m)
print("deps ok")
PY

COPY app/main.py .
COPY app/wizexercise.txt .
EXPOSE 8080
CMD ["python","-m","uvicorn","main:app","--host","0.0.0.0","--port","8080"]

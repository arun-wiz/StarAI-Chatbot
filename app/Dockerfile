# app/Dockerfile
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Upgrade toolchain
RUN python -m pip install --upgrade pip setuptools wheel

# Copy requirements
COPY app/requirements.txt /app/requirements.txt

# Cache-buster: pass REQ_SHA from Jenkins; any change retriggers install
ARG REQ_SHA=dev
RUN echo "REQ_SHA=${REQ_SHA}"

# Install deps and HARD-FAIL if imports don’t work
RUN python -m pip install --no-cache-dir -r /app/requirements.txt \
 && python - <<'PY'
import importlib
for m in ("fastapi","uvicorn","httpx","pymongo"):
    importlib.import_module(m)
print("deps ok")
PY

# App code
COPY app/main.py /app/main.py

EXPOSE 8080
CMD ["python","-m","uvicorn","main:app","--host","0.0.0.0","--port","8080"]

# app/Dockerfile

FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip

RUN python -m pip install --upgrade setuptools wheel

COPY app/requirements.txt /app/requirements.txt

# cache-buster (you already pass --build-arg=REQ_SHA=…)
ARG REQ_SHA=dev
RUN echo "REQ_SHA=${REQ_SHA}"

# Install deps and hard-fail if missing
RUN python -m pip install --no-cache-dir -r /app/requirements.txt \
 && python - <<'PY'
import importlib
for m in ("fastapi","uvicorn","httpx","pymongo"):
    importlib.import_module(m)
print("deps ok")
PY

COPY app/main.py /app/main.py
COPY app/wizexercise.txt /app/wizexercise.txt
EXPOSE 8080
CMD ["python","-m","uvicorn","main:app","--host","0.0.0.0","--port","8080"]

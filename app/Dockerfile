FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# ⛔️ Remove pip upgrade lines – avoid the flake

COPY app/requirements.txt /app/requirements.txt

# cache-buster
ARG REQ_SHA=dev
RUN echo "REQ_SHA=${REQ_SHA}"

# install deps and hard-fail if missing
RUN python -m pip install --no-cache-dir -r /app/requirements.txt \
 && python - <<'PY'
import importlib
for m in ("fastapi","uvicorn","httpx","pymongo"):
    importlib.import_module(m)
print("deps ok")
PY

COPY app/main.py /app/main.py
EXPOSE 8080
CMD ["python","-m","uvicorn","main:app","--host","0.0.0.0","--port","8080"]

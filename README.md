# Langflow 1.2.0 Chatbot on EKS (MongoDB on EC2). 
##Test the Langflow vulnerability

This deploys:
- **Langflow 1.2.0** (ClusterIP)
- **FastAPI Gateway** (ClusterIP) exposing:
  - `GET /health`
  - `GET /api/services`
  - `POST /chat`
  - `POST /api/v1/validate/code` 

MongoDB runs on **your EC2**. The app connects via `MONGO_URI`.

## Prereqs
- EKS cluster with **AWS Load Balancer Controller**
- ACM certificate in same region
- Jenkins (with k8s agents, `kubectl` access, and ECR push via IRSA or node role)

## Persistence (FLOW_ID survives restarts)

Langflow’s flow metadata and IDs live in a SQLite DB. We now mount a PVC so the DB persists:

- PVC: `k8s/app-langflow/pvc.yaml`
- Mounted at `/data` in the Langflow container
- Langflow DB URL: `sqlite:////data/langflow.db`

This ensures your `FLOW_ID` remains stable across Pod restarts and rollouts. If you ever delete the PVC, you’ll need to recreate your flow and update `FLOW_ID` in the ConfigMap.

## Quick start (manual)
```bash
# 1) Set your EC2 Mongo IP/DNS in k8s/gateway/app-configmap.yaml
# 2) Set your domain + ACM ARN in k8s/ingress/alb-ingress.yaml
# 3) Apply
kubectl apply -f k8s/namespace.yaml
kubectl -n chatbot apply -f k8s/langflow/
kubectl -n chatbot apply -f k8s/gateway/
kubectl -n chatbot apply -f k8s/ingress/alb-ingress.yaml

# Port-forward Langflow to create a flow and get FLOW_ID (or temporarily expose)
kubectl -n chatbot port-forward deploy/langflow 7860:7860
# Open http://localhost:7860, build a flow expecting 'context' & chat 'input'
# Share -> copy FLOW_ID -> update k8s/gateway/app-configmap.yaml
kubectl -n chatbot rollout restart deploy/chatbot-app

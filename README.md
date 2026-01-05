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
- GitHub Actions with AWS IAM Role via OIDC

## GitHub Actions setup
 
Configure the following in your GitHub repo:
 
**Repo Variables**
- **EKS_CLUSTER_NAME**
- **EKS_REGION**
- **ECR_ACCOUNT**
- **ECR_REGION**
- **ECR_REPO**
- **PUBLIC_DOMAIN**
- **ALB_ACM_ARN**
- **FLOW_ID**
- **DEMO_MODE** (set to `true` to use HTTP-only ALB ingress and print the ALB DNS)
 
**Repo Secrets**
- **AWS_ROLE_TO_ASSUME** (IAM Role ARN for OIDC)
- **MONGO_USER**
- **MONGO_PASS**
- **MONGO_HOST**
- **OPENAI_API_KEY** (optional)

 The IAM role should trust GitHub's OIDC provider and allow:
 - `ecr:DescribeRepositories`, `ecr:CreateRepository` (for ephemeral accounts)
 - `ecr:*` actions required to push images
 - `eks:DescribeCluster`
 - `eks:CreateAccessEntry` and `eks:AssociateAccessPolicy` (only if you want the workflow to self-grant EKS access)

 When `DEMO_MODE=true`, the deployment uses `manifests/ingress-demo.yaml` (no host / no ACM cert) and prints a demo URL like:
 `http://<alb-dns-name>/`

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

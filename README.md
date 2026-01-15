# Langflow 1.2.0 Chatbot on EKS (MongoDB on EC2). 
##Sample application to test the Langflow vulnerability

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
- **FLOW_ID**
  
 The workflow is intended to be run manually via `workflow_dispatch`.
 
 - Use `demo_mode=true` for ephemeral/demo accounts (HTTP-only ALB ingress, prints the ALB DNS)
 - Use `demo_mode=false` for custom domain + TLS (requires `public_domain` and `alb_acm_arn` inputs)
 - Provide `langflow_seed_image` to seed Langflow's SQLite DB on every fresh cluster
 
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

 When `demo_mode=true`, the deployment uses `manifests/ingress-demo.yaml` (no host / no ACM cert) and prints a demo URL like:
 `http://<alb-dns-name>/`

 ## Langflow seed image (ephemeral clusters)
 
 Since the entire cluster is ephemeral, Langflow's SQLite DB is seeded via an initContainer.
 Seeding is optional:
 - If you provide `langflow_seed_image`, the deployment seeds `/data/langflow.db` before Langflow starts.
 - If you omit it, Langflow will start with a fresh DB and you can build the flow in the running environment.

 ### Build the flow in EKS and export `langflow.db`
 
 1) Deploy the stack once (any mode) so the `chatbot` pod exists.
 2) Port-forward Langflow locally:
 
 ```bash
 kubectl -n chatbot port-forward deploy/chatbot 7860:7860
 ```
 
 3) Open Langflow in your browser: `http://localhost:7860`
 4) Create your flow and record the `FLOW_ID`.
 5) Copy the SQLite DB out of the running pod:
 
 ```bash
 POD="$(kubectl -n chatbot get pod -l app=chatbot -o jsonpath='{.items[0].metadata.name}')"
 kubectl -n chatbot cp "$POD:/data/langflow.db" ./langflow-seed/langflow.db
 ```
 
 ### Build/push the seed image to DockerHub (GitHub Actions)
 
 This repo includes a manual workflow: `.github/workflows/build-langflow-seed-image.yml`.
 
 - Add GitHub Secrets:
   - `DOCKERHUB_USERNAME`
   - `DOCKERHUB_TOKEN`
 - Ensure `langflow-seed/langflow.db` exists in the repo workspace.
 - Run the workflow and set:
   - `image_name` = `yourdockerhubuser/langflow-seed`
   - `image_tag` = `1.0.0`

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

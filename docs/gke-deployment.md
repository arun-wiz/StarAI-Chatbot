# GKE Deployment Notes

## Current Repo Shape

This repo already has a working Kubernetes deployment model, but the cloud integration is AWS-specific in a few places:

- Image publishing assumes ECR.
- Cluster access assumes EKS via `aws eks update-kubeconfig`.
- Persistent storage assumes EBS-backed StorageClasses.
- Public ingress assumes the AWS Load Balancer Controller and ALB annotations.
- The legacy pipeline is archived in [archive/Jenkinsfile](../archive/Jenkinsfile) and mirrors the same AWS assumptions.

The application manifests themselves are mostly portable:

- The gateway image is built from [app/Dockerfile](../app/Dockerfile).
- The runtime deployment is a single pod with two containers: FastAPI gateway plus Langflow sidecar.
- Runtime data is persisted in a PVC at `/data/langflow.db`.
- MongoDB stays external and is injected through `MONGO_URI`.

For the AWS/EKS naming and compatibility notes, see [aws-eks-deployment.md](aws-eks-deployment.md).

## AWS to GCP Mapping

| AWS / current repo | GCP / new path |
| --- | --- |
| ECR repository | Artifact Registry Docker repo |
| EKS cluster auth via AWS OIDC role | GCP Workload Identity Federation via `google-github-actions/auth` |
| `aws eks update-kubeconfig` | `google-github-actions/get-gke-credentials` / `gcloud container clusters get-credentials` |
| EBS StorageClass `ebs-gp3-sc` | GKE Persistent Disk CSI class `standard-rwo` |
| ALB ingress annotations | GKE Ingress with `kubernetes.io/ingress.class: "gce"` |
| ACM certificate ARN on ingress | GKE `ManagedCertificate` resource |
| Jenkins Kaniko push to ECR | GitHub Actions Buildx push to Artifact Registry |

## Added in This Repo

- `.github/workflows/deploy-gke.yml`
- `ci/apply_gke_secrets.sh`
- `ci/deploy_gke.sh`
- `manifests/pvc-gke.yaml`
- `manifests/service-gke.yaml`
- `manifests/ingress-gke.yaml`
- `manifests/ingress-gke-demo.yaml`
- `manifests/managedcertificate.yaml`

## GitHub Configuration for GKE Workflow

Repository variables:

- `GCP_PROJECT_ID`
- `GAR_LOCATION`
- `GAR_REPOSITORY` (repository name only, for example `star-ai`)
- `GKE_CLUSTER_NAME`
- `GKE_LOCATION`
- `FLOW_ID`
- `GKE_STATIC_IP_NAME` (optional)

Optional AI agent demo variables:

- `AGENT_PROVIDER`
- `AGENT_STORAGE_PROVIDER`
- `AGENT_PII_BUCKET`
- `AGENT_DEMO_UNSAFE`
- `GCP_AGENT_SERVICE_ACCOUNT`
- `VERTEX_PROJECT_ID`
- `VERTEX_LOCATION`
- `VERTEX_MODEL_ID`

The GKE workflow can now provision the GCP agent demo resources automatically with the `provision_agent_demo_resources` workflow input, which defaults to `true`. In that mode, the workflow bootstraps an AWS S3/DynamoDB Terraform backend if it does not exist, applies `infra/gcp/agent-demo`, and passes the generated values directly to the Kubernetes deployment.

For the full agent setup, see [agent-demo.md](agent-demo.md).

Repository secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`
- `MONGO_USER`
- `MONGO_PASS`
- `GCP_MONGO_HOST` (preferred for the GKE workflow)
- `MONGO_HOST` (legacy/shared fallback)
- `OPENAI_API_KEY` (optional)

## Workflow Behavior

The `Deploy to GKE` workflow:

1. Authenticates to GCP with Workload Identity Federation.
2. Ensures the Artifact Registry Docker repository exists, creating it when missing.
3. Grants `roles/artifactregistry.reader` on that repository to the GKE node service account so nodes can pull the private gateway image.
4. Logs in to Artifact Registry.
5. Builds and pushes the gateway image to GAR.
6. Fetches kubeconfig for the target GKE cluster.
7. Creates or updates Mongo/OpenAI Kubernetes secrets.
8. Applies the namespace, service account, cluster role binding, GKE-specific PVC, Service, Ingress, and optional ManagedCertificate.
9. Rolls the `chatbot` deployment and waits for ingress IP allocation.

## Notes

- `demo_mode=true` keeps the ingress HTTP-only and does not require DNS or TLS.
- `demo_mode=false` expects a DNS name and creates a Google-managed certificate resource.
- The GCP service account used by GitHub Actions needs Artifact Registry admin-capable permissions to create the repository on first deploy and set the repository IAM policy. It also needs permission to describe the target GKE cluster so the workflow can discover the node service account.
- GKE image pulls use the node pool's Google service account, not the Kubernetes service account in `manifests/serviceaccount.yaml`. The workflow resolves GKE's `default` node service account to `<PROJECT_NUMBER>-compute@developer.gserviceaccount.com` and grants it repository-scoped Artifact Registry read access.
- The GKE deploy path now applies the same `clusterrolebinding.yaml` as EKS so the `chatbot-admin` service account is bound to `cluster-admin`.
- That RBAC change gives the workload broad Kubernetes API access, but it does not by itself make the container runtime `privileged: true`; if you also need host-level Linux privileges, that requires explicit container `securityContext` changes and a compatible GKE cluster mode.

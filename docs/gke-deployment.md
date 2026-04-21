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
- `GAR_REPOSITORY`
- `GKE_CLUSTER_NAME`
- `GKE_LOCATION`
- `FLOW_ID`
- `GKE_STATIC_IP_NAME` (optional)

Repository secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`
- `MONGO_USER`
- `MONGO_PASS`
- `MONGO_HOST`
- `OPENAI_API_KEY` (optional)

## Workflow Behavior

The `Deploy to GKE` workflow:

1. Authenticates to GCP with Workload Identity Federation.
2. Logs in to Artifact Registry.
3. Builds and pushes the gateway image to GAR.
4. Fetches kubeconfig for the target GKE cluster.
5. Creates or updates Mongo/OpenAI Kubernetes secrets.
6. Applies the GKE-specific PVC, Service, Ingress, and optional ManagedCertificate.
7. Rolls the `chatbot` deployment and waits for ingress IP allocation.

## Notes

- `demo_mode=true` keeps the ingress HTTP-only and does not require DNS or TLS.
- `demo_mode=false` expects a DNS name and creates a Google-managed certificate resource.
- The GKE deploy path intentionally does not apply the repo's `clusterrolebinding.yaml`; the current application code does not call the Kubernetes API, so cluster-admin on the workload was unnecessary for this path.

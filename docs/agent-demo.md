# AI Agent PII Demo

This repo now has an optional customer-operations agent beside the existing Langflow chatbot.

- `POST /chat` keeps the original Mongo-grounded Langflow flow.
- `POST /agent/chat` runs the new AI agent path.
- The browser UI at `/` has a `mode` selector for `services` or `agent`.

The agent can read the synthetic PII datasets from local image files, S3, or GCS:

- `data/customer_pii.csv`
- `data/payment_records.csv`

## Runtime Settings

Set these as GitHub repository variables or render them into `manifests/configmap.yaml`.

| Setting | Values | Default |
| --- | --- | --- |
| `AGENT_PROVIDER` | `local`, `bedrock`, `bedrock-agent`, `vertex` | `local` |
| `AGENT_STORAGE_PROVIDER` | `local`, `s3`, `gcs` | `local` |
| `AGENT_PII_BUCKET` | S3 or GCS bucket name | empty |
| `AGENT_CUSTOMER_OBJECT` | Customer CSV object key | `customer_pii.csv` |
| `AGENT_PAYMENTS_OBJECT` | Payments CSV object key | `payment_records.csv` |
| `AGENT_DEMO_UNSAFE` | `true` returns raw sensitive fields from tools | `false` |
| `BEDROCK_MODEL_ID` | Bedrock model ID or inference profile ID | `anthropic.claude-3-haiku-20240307-v1:0` |
| `BEDROCK_AGENT_ID` | Managed Bedrock Agent ID | empty |
| `BEDROCK_AGENT_ALIAS_ID` | Managed Bedrock Agent alias ID | empty |
| `VERTEX_PROJECT_ID` | GCP project for Vertex AI | empty |
| `VERTEX_LOCATION` | Vertex AI location | `us-central1` |
| `VERTEX_MODEL_ID` | Gemini model ID | `gemini-2.5-flash` |

`AGENT_DEMO_UNSAFE=false` keeps email, phone, address, SSN, card, and expiry values masked. Set it to `true` only in a synthetic-data demo environment.

## Local Demo

The gateway image copies `data/` into `/app/data`, so no cloud setup is needed:

```bash
curl -s http://localhost:8080/agent/chat \
  -H 'content-type: application/json' \
  -d '{"message":"Export CUST-20001"}' | jq
```

With the default masked mode, the agent can prove it has access to the customer and payment rows without disclosing raw SSNs or card numbers.

## AWS Bedrock + S3 Demo

The EKS workflow now provisions the AWS backing resources with Terraform when the workflow input `provision_agent_demo_resources` is `true` (default).

Before running Terraform, the workflow checks for the AWS Terraform backend resources and creates them when missing:

- S3 state bucket: `starai-terraform-state-<account-id>-<backend-region>`
- DynamoDB lock table: `starai-terraform-locks`

The S3 state bucket has versioning, AES-256 encryption, and public access block enabled. Terraform then uses the S3 bucket and DynamoDB table as its backend.
Set `AWS_TERRAFORM_BACKEND_REGION` if you want the backend in a specific AWS region; otherwise the EKS workflow derives it from the configured AWS region.

Terraform creates or updates:

- An S3 bucket with the synthetic PII CSV objects.
- An IRSA role trusted by the `chatbot/chatbot-admin` Kubernetes service account.
- An intentionally broad demo policy with `s3:*` on the PII bucket and Bedrock invoke permissions.

This path does not create a managed resource in the Bedrock Agents console. `AGENT_PROVIDER=bedrock` uses the app's `/agent/chat` route to call the Bedrock Runtime Converse API directly, while the gateway performs the S3-backed tool calls. The created AWS resources are the S3 bucket, IAM role, IAM policy, and S3 objects.

It then deploys the app with:

```text
AGENT_PROVIDER=bedrock
AGENT_STORAGE_PROVIDER=s3
AGENT_PII_BUCKET=<created bucket>
AGENT_DEMO_UNSAFE=true
AWS_AGENT_ROLE_ARN=<created role>
```

You do not need to define those repository variables when pipeline provisioning is enabled. Use the optional workflow input `bedrock_model_id` if you want to override the default model.

The AWS role used by GitHub Actions must be allowed to create or update S3 buckets, DynamoDB tables, IAM roles/policies, the EKS OIDC provider, and S3 objects. Bedrock model access still needs to be enabled in the AWS account for the selected model.

The optional Terraform in `infra/aws/agent-demo` is still available if you want to create the same resources manually or show them as IaC in Wiz.

Example:

```bash
cd infra/aws/agent-demo
terraform init
terraform apply \
  -var='bucket_name=starai-agent-pii-demo-ACCOUNT-REGION' \
  -var='eks_oidc_provider_arn=arn:aws:iam::ACCOUNT:oidc-provider/oidc.eks.REGION.amazonaws.com/id/EXAMPLE' \
  -var='eks_oidc_issuer_url=https://oidc.eks.REGION.amazonaws.com/id/EXAMPLE'
```

If you disable pipeline provisioning, set these GitHub repository variables for EKS deployments:

```text
AGENT_PROVIDER=bedrock
AGENT_STORAGE_PROVIDER=s3
AGENT_PII_BUCKET=<terraform output agent_pii_bucket>
AGENT_DEMO_UNSAFE=true
AWS_AGENT_ROLE_ARN=<terraform output agent_role_arn>
BEDROCK_MODEL_ID=<your enabled Bedrock model or inference profile>
```

The EKS deploy script annotates `chatbot-admin` with `eks.amazonaws.com/role-arn` when `AWS_AGENT_ROLE_ARN` is set.

For a managed Bedrock Agent, set:

```text
AGENT_PROVIDER=bedrock-agent
BEDROCK_AGENT_ID=<agent id>
BEDROCK_AGENT_ALIAS_ID=<alias id>
```

In that mode, `/agent/chat` forwards to Bedrock Agent Runtime instead of using the gateway's local tool loop.

## GCP Vertex AI + GCS Demo

The GKE workflow now provisions the GCP backing resources with Terraform when the workflow input `provision_agent_demo_resources` is `true` (default).

The GKE workflow uses a GCS Terraform backend. Before running Terraform, it checks for the backend bucket and creates it when missing:

- GCS state bucket: `starai-tf-state-<project-number>-<location>`

The GCS state bucket has versioning, uniform bucket-level access, and public-access prevention enabled. The GKE workflow no longer needs AWS credentials for Terraform state.

Terraform creates or updates:

- A GCS bucket with the synthetic PII CSV objects.
- A Google service account for the agent.
- Intentionally broad `roles/storage.admin` on the PII bucket.
- `roles/aiplatform.user` for Vertex AI calls.
- A Workload Identity binding for `chatbot/chatbot-admin`.

It then deploys the app with:

```text
AGENT_PROVIDER=vertex
AGENT_STORAGE_PROVIDER=gcs
AGENT_PII_BUCKET=<created bucket>
AGENT_DEMO_UNSAFE=true
GCP_AGENT_SERVICE_ACCOUNT=<created service account>
```

You do not need to define those repository variables when pipeline provisioning is enabled. Use the optional workflow input `vertex_model_id` if you want to override the default model.

The GCP service account used by GitHub Actions must be allowed to enable services, create or update GCS buckets, create service accounts, set IAM policies, and use Vertex AI. The target GKE cluster must have Workload Identity enabled for the pod to assume the created Google service account.

The optional Terraform in `infra/gcp/agent-demo` is still available if you want to create the same resources manually or show them as IaC in Wiz.

Example:

```bash
cd infra/gcp/agent-demo
terraform init
terraform apply \
  -var='project_id=YOUR_PROJECT_ID' \
  -var='bucket_name=starai-agent-pii-demo-YOUR_PROJECT_ID'
```

If you disable pipeline provisioning, set these GitHub repository variables for GKE deployments:

```text
AGENT_PROVIDER=vertex
AGENT_STORAGE_PROVIDER=gcs
AGENT_PII_BUCKET=<terraform output agent_pii_bucket>
AGENT_DEMO_UNSAFE=true
GCP_AGENT_SERVICE_ACCOUNT=<terraform output agent_service_account_email>
VERTEX_PROJECT_ID=<project id>
VERTEX_LOCATION=us-central1
VERTEX_MODEL_ID=<your Gemini model>
```

The GKE deploy script annotates `chatbot-admin` with `iam.gke.io/gcp-service-account` when `GCP_AGENT_SERVICE_ACCOUNT` is set.

## Demo Prompts

```text
What PII objects can you access?
Look up customer CUST-20001
Show payment records for card ending 1111
Export CUST-20001
```

## Wiz Storyline

The intended graph is:

```text
Internet-exposed chatbot
  -> vulnerable/old Langflow sidecar image
  -> Kubernetes service account with cluster-admin
  -> cloud agent identity with broad bucket privileges
  -> storage bucket containing synthetic PII
```

The CI workflows already run Wiz scans for code, IaC, sensitive data, and container images. The new Terraform templates and copied image data give Wiz additional cloud/IaC relationships to show during the demo.

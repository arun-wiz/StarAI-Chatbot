# AWS EKS Deployment Notes

## AWS/EKS Files

The AWS deployment path now uses AWS/EKS-specific file names:

- `ci/deploy_aws_eks.sh`
- `ci/apply_aws_eks_secrets.sh`

The older wrappers remain in place for compatibility:

- `ci/deploy.sh`
- `ci/apply_db_secret.sh`

## Preferred AWS/EKS Variables

Repository or pipeline variables:

- `AWS_EKS_CLUSTER_NAME`
- `AWS_EKS_REGION`
- `AWS_ECR_ACCOUNT`
- `AWS_ECR_REGION`
- `AWS_ECR_REPO`
- `AWS_ECR_IMAGE`
- `AWS_ECR_IMAGE_TAGGED`
- `AWS_PUBLIC_DOMAIN`
- `AWS_ALB_ACM_ARN`

Generic application variables that remain shared across clouds:

- `FLOW_ID`
- `LANGFLOW_SEED_IMAGE`
- `MONGO_USER`
- `MONGO_PASS`
- `MONGO_HOST`
- `OPENAI_API_KEY`

## Backward Compatibility

The AWS/EKS scripts still accept the legacy names:

- `EKS_CLUSTER_NAME`
- `EKS_CLUSTER_NAME_B`
- `EKS_REGION`
- `EKS_REGION_B`
- `ECR_IMAGE_TAGGED`
- `PUBLIC_DOMAIN`
- `ALB_ACM_ARN`

The new AWS-prefixed names take precedence when both are present.

## AWS/EKS Flow

1. Build and push the gateway image to ECR.
2. Update kubeconfig against EKS.
3. Create or update Mongo/OpenAI Kubernetes secrets.
4. Apply the EKS manifests, including the AWS storage class and ALB ingress.

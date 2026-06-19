terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for the StarAI synthetic PII demo data."
}

variable "namespace" {
  type    = string
  default = "chatbot"
}

variable "service_account_name" {
  type    = string
  default = "chatbot-admin"
}

variable "eks_oidc_provider_arn" {
  type        = string
  description = "EKS OIDC provider ARN used for IRSA trust."
}

variable "eks_oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL, for example https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE."
}

variable "bedrock_model_arns" {
  type        = list(string)
  description = "Bedrock model or inference profile ARNs the demo role can invoke."
  default     = ["*"]
}

locals {
  oidc_hostpath = replace(var.eks_oidc_issuer_url, "https://", "")
}

resource "aws_s3_bucket" "starai_agent_pii" {
  bucket = var.bucket_name

  tags = {
    project      = "starai-chatbot"
    demo         = "ai-agent-pii"
    data_profile = "synthetic-pii"
  }
}

resource "aws_s3_object" "customer_pii" {
  bucket       = aws_s3_bucket.starai_agent_pii.id
  key          = "customer_pii.csv"
  source       = "${path.module}/../../../data/customer_pii.csv"
  content_type = "text/csv"
}

resource "aws_s3_object" "payment_records" {
  bucket       = aws_s3_bucket.starai_agent_pii.id
  key          = "payment_records.csv"
  source       = "${path.module}/../../../data/payment_records.csv"
  content_type = "text/csv"
}

resource "aws_iam_role" "starai_agent" {
  name = "starai-agent-pii-demo"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_hostpath}:aud" = "sts.amazonaws.com"
            "${local.oidc_hostpath}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
          }
        }
      }
    ]
  })

  tags = {
    project = "starai-chatbot"
    demo    = "intentionally-overprivileged-agent"
  }
}

resource "aws_iam_policy" "starai_agent_pii_access" {
  name        = "starai-agent-pii-demo-access"
  description = "Demo policy: intentionally broad PII bucket and Bedrock access for Wiz visibility."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IntentionallyBroadPiiBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = [
          aws_s3_bucket.starai_agent_pii.arn,
          "${aws_s3_bucket.starai_agent_pii.arn}/*"
        ]
      },
      {
        Sid    = "InvokeBedrockModels"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = var.bedrock_model_arns
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "starai_agent_pii_access" {
  role       = aws_iam_role.starai_agent.name
  policy_arn = aws_iam_policy.starai_agent_pii_access.arn
}

output "agent_pii_bucket" {
  value = aws_s3_bucket.starai_agent_pii.bucket
}

output "agent_role_arn" {
  value = aws_iam_role.starai_agent.arn
}

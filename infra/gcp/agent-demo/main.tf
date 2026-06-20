terraform {
  backend "s3" {}

  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "GCP project ID for the StarAI synthetic PII demo."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "bucket_name" {
  type        = string
  description = "Globally unique GCS bucket name for the StarAI synthetic PII demo data."
}

variable "namespace" {
  type    = string
  default = "chatbot"
}

variable "service_account_name" {
  type    = string
  default = "chatbot-admin"
}

resource "google_project_service" "aiplatform" {
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "starai_agent_pii" {
  name                        = var.bucket_name
  location                    = upper(var.region)
  uniform_bucket_level_access = true

  labels = {
    project      = "starai-chatbot"
    demo         = "ai-agent-pii"
    data_profile = "synthetic-pii"
  }

  depends_on = [google_project_service.storage]
}

resource "google_storage_bucket_object" "customer_pii" {
  name         = "customer_pii.csv"
  bucket       = google_storage_bucket.starai_agent_pii.name
  source       = "${path.module}/../../../data/customer_pii.csv"
  content_type = "text/csv"
}

resource "google_storage_bucket_object" "payment_records" {
  name         = "payment_records.csv"
  bucket       = google_storage_bucket.starai_agent_pii.name
  source       = "${path.module}/../../../data/payment_records.csv"
  content_type = "text/csv"
}

resource "google_service_account" "starai_agent" {
  account_id   = "starai-agent-pii-demo"
  display_name = "StarAI agent PII demo"
  description  = "Demo identity with intentionally broad PII bucket access for Wiz visibility."
}

resource "google_storage_bucket_iam_member" "starai_agent_storage_admin" {
  bucket = google_storage_bucket.starai_agent_pii.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.starai_agent.email}"
}

resource "google_project_iam_member" "starai_agent_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.starai_agent.email}"

  depends_on = [google_project_service.aiplatform]
}

resource "google_service_account_iam_member" "starai_agent_workload_identity" {
  service_account_id = google_service_account.starai_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.service_account_name}]"
}

output "agent_pii_bucket" {
  value = google_storage_bucket.starai_agent_pii.name
}

output "agent_service_account_email" {
  value = google_service_account.starai_agent.email
}

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# AWS — cloud primario. Ejecutar siempre con: AWS_PROFILE=hvillavicencio terraform ...
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Talk      = "aws-community-day-gt-2026"
    }
  }
}

# GCP — warm standby. Autenticación vía token de gcloud:
#   export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

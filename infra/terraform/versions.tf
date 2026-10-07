terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State holds resource metadata and must be treated as sensitive. Encrypted,
  # versioned, locked, and in the customer's account — not ours.
  backend "s3" {
    # Values supplied at init time; see docs/runbook.md
    # bucket         = "cascade-tfstate-<account-id>"
    # key            = "support-agent/terraform.tfstate"
    # region         = "eu-west-2"
    # dynamodb_table = "cascade-tfstate-lock"
    # encrypt        = true
    # kms_key_id     = "alias/cascade-tfstate"
  }
}

provider "aws" {
  region = var.region

  # Every API call this stack makes is attributable to the deployment, and
  # refuses to run against the wrong account.
  allowed_account_ids = [var.customer_account_id]

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Repo      = "agent-deployment"
    }
  }
}

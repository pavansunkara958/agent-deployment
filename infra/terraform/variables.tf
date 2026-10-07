variable "region" {
  description = "Customer region. Data residency requires eu-west-2."
  type        = string
  default     = "eu-west-2"

  validation {
    condition     = can(regex("^eu-", var.region))
    error_message = "Data residency: EU regions only."
  }
}

variable "customer_account_id" {
  description = "Customer AWS account. Guards against deploying to the wrong one."
  type        = string
}

variable "customer_prefix" {
  description = "Customer short name, used in every resource name."
  type        = string
  default     = "cascade"
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "owning_team" {
  description = "Team that owns this after handover. Required — an unowned service rots."
  type        = string
}

variable "cost_centre" {
  type = string
}

# --- Network -----------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  description = "One NAT instead of one per AZ. Cheaper; a single AZ failure takes egress with it."
  type        = bool
  default     = false
}

variable "enable_network_firewall" {
  description = "Hostname-level egress allow-list. Adds cost; required for PCI scope."
  type        = bool
  default     = true
}

variable "allowed_egress_hosts" {
  description = "The ONLY hostnames the agent may reach outside AWS."
  type        = list(string)
  default     = ["api.groq.com"]
}

variable "model_base_url" {
  type    = string
  default = "https://api.groq.com/openai/v1"
}

# --- Compute -----------------------------------------------------------------
variable "task_cpu" {
  type    = string
  default = "512"
}

variable "task_memory" {
  type    = string
  default = "1024"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "image_tag" {
  description = "Immutable image tag. Never 'latest' — a tag you cannot pin is a deploy you cannot reproduce."
  type        = string

  validation {
    condition     = var.image_tag != "latest"
    error_message = "Use an immutable tag (a git sha), not 'latest'."
  }
}

# --- Observability -----------------------------------------------------------
variable "metric_namespace" {
  type    = string
  default = "Cascade/SupportAgent"
}

variable "log_retention_days" {
  description = "90 days matches the customer's support-transcript retention policy."
  type        = number
  default     = 90
}

# --- Access ------------------------------------------------------------------
variable "ci_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider in the customer account. No long-lived CI keys."
  type        = string
}

variable "ci_repo" {
  description = "org/repo permitted to deploy."
  type        = string
}

variable "breakglass_principal_arns" {
  description = "Named humans who may assume the break-glass role."
  type        = list(string)
}

variable "pci_data_bucket" {
  description = "Cardholder-data bucket the agent is explicitly denied."
  type        = string
}

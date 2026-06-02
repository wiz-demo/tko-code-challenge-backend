# =============================================================================
# Wiz Provider Variables
# =============================================================================

variable "wiz_client_id" {
  description = "Wiz service account client ID. Generate at Wiz Console > Settings > Service Accounts."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.wiz_client_id) > 0
    error_message = "wiz_client_id must not be empty."
  }
}

variable "wiz_client_secret" {
  description = "Wiz service account client secret."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.wiz_client_secret) > 0
    error_message = "wiz_client_secret must not be empty."
  }
}

variable "wiz_env" {
  description = "Wiz environment to target (test, prod, etc.)."
  type        = string
  default     = "test"
}

# =============================================================================
# AWS Provider Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region for provider configuration. SCP-allowed values only."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2"], var.aws_region)
    error_message = "aws_region must be us-east-1, us-east-2, or us-west-2 (SCP-allowed)."
  }
}

variable "aws_profile" {
  description = "AWS named profile that maps to the target account (800618367342)."
  type        = string
  default     = "dev-product-cto-play"
}

variable "owner" {
  description = "Required `owner` tag (mandatory in this playground account per CLAUDE.md)."
  type        = string
  default     = "itay.katz"
}

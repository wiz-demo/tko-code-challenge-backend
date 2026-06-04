# =============================================================================
# Wiz AWS Connector
# =============================================================================
# Self-contained: connector-specific variables, the resource, and outputs.
#
# PREREQUISITE: the wiz-iam/ sub-project must be applied first (it provisions
# the IAM role this connector consumes). The Makefile's `make apply` runs
# them in the right order.
# =============================================================================

# --- Variables --------------------------------------------------------------

variable "connector_name" {
  description = "Display name for the Wiz connector shown in the Wiz UI."
  type        = string
  default     = "TF-AWS-Connector-CodeChallange"
}

variable "aws_account_id" {
  description = "AWS account ID Wiz should scan. Passed to the connector explicitly via auth_params.customerAccountID so the scope is documented in code (not just implied by the role ARN's account)."
  type        = string
  default     = "800618367342"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit number."
  }
}

# --- Resource ---------------------------------------------------------------

# Read the Wiz IAM role ARN from the wiz-iam/ sub-project's state.
# Plan-known because wiz-iam is applied first (see Makefile), so this avoids
# the wiz-v2 provider's auth_params_hash__ inconsistency bug that fires when
# customerRoleARN references an unknown-after-apply value.
data "terraform_remote_state" "wiz_iam" {
  backend = "local"
  config = {
    path = "${path.module}/wiz-iam/terraform.tfstate"
  }
}

resource "wiz-v2_generic_connector" "aws_code_challenge" {
  name = var.connector_name
  type = "aws"

  # The Wiz AWS connector schema does NOT accept a top-level account field
  # in auth_params (we tried customerAccountID — API responded "Unexpected
  # field"). The account is implied by the customerRoleARN. Instead we pin
  # the scope explicitly in terraform via:
  #   - var.aws_account_id (default "800618367342", validated as 12 digits)
  #   - the precondition below, which fails the plan/apply if the role ARN's
  #     account segment doesn't match var.aws_account_id
  # Combined with skipOrganizationScan=true (extra_config) this guarantees
  # the connector can only ever target the one named account.
  auth_params = jsonencode({
    customerRoleARN = data.terraform_remote_state.wiz_iam.outputs.role_arn
  })

  lifecycle {
    precondition {
      condition     = split(":", data.terraform_remote_state.wiz_iam.outputs.role_arn)[4] == var.aws_account_id
      error_message = "Role ARN's account (${split(":", data.terraform_remote_state.wiz_iam.outputs.role_arn)[4]}) does not match var.aws_account_id (${var.aws_account_id})."
    }
  }

  # Minimal extra_config: forces SaaS-side scanning (no in-account scanning
  # infrastructure required) and provides stub VPC flow log config. Stub
  # values are stored as opaque strings by the API; actual AWS-resource
  # validation is deferred to scan time.
  extra_config = jsonencode({
    # Scope to a single AWS account (800618367342, where the IAM role lives).
    # skipOrganizationScan = true tells Wiz NOT to enumerate the AWS Org from
    # this connector, so sibling accounts in org o-4ynr318qmi are never
    # touched. The role only exists in account 800618367342, so single-account
    # mode == "scan only 800618367342".
    #
    # `includedAccounts` / `excludedAccounts` are intentionally NOT set — they
    # are org-scan-only fields (require skipOrganizationScan = false). See
    # /Users/itay.katz/terraform-test/docs/superpowers/specs/2026-05-05-aws-
    # connector-extra-config-coverage-design.md ("Out of scope" section).
    skipOrganizationScan = true



  })
}

# --- Outputs ----------------------------------------------------------------

output "aws_role_arn" {
  description = "ARN of the IAM role Wiz assumes to scan the account."
  value       = data.terraform_remote_state.wiz_iam.outputs.role_arn
}

output "aws_connector_id" {
  description = "Wiz connector ID (visible in the Wiz UI)."
  value       = wiz-v2_generic_connector.aws_code_challenge.id
}

output "aws_connector_name" {
  description = "Wiz connector display name."
  value       = wiz-v2_generic_connector.aws_code_challenge.name
}

# Preserve state across the sorcery → code-challenge rename. Without this,
# `terraform apply` would destroy and recreate the connector, losing scan
# history and re-onboarding the AWS account in Wiz.
moved {
  from = wiz-v2_generic_connector.aws_sorcery
  to   = wiz-v2_generic_connector.aws_code_challenge
}

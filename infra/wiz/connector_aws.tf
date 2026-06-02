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
  description = "AWS account ID to scan (optional, auto-detected if not provided)."
  type        = string
  default     = ""

  validation {
    condition     = var.aws_account_id == "" || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit number or empty."
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

resource "wiz-v2_generic_connector" "aws_sorcery" {
  name = var.connector_name
  type = "aws"

  auth_params = jsonencode({
    customerRoleARN = data.terraform_remote_state.wiz_iam.outputs.role_arn
  })

  # Minimal extra_config: forces SaaS-side scanning (no in-account scanning
  # infrastructure required) and provides stub VPC flow log config. Stub
  # values are stored as opaque strings by the API; actual AWS-resource
  # validation is deferred to scan time.
  extra_config = jsonencode({
    securityToolScanningSettings = {
      bucketConfig            = { forceScanMethod = "SAAS" }
      containerImageConfig    = { forceScanMethod = "SAAS" }
      dataWorkloadConfig      = { forceScanMethod = "SAAS" }
      databaseConfig          = { forceScanMethod = "SAAS" }
      fileSystemServiceConfig = { forceScanMethod = "SAAS" }
      serverlessConfig        = { forceScanMethod = "SAAS" }
      virtualMachineConfig    = { forceScanMethod = "SAAS" }
    }
    vpcFlowLogConfig = {
      bucketName          = "wiz-stub-vpcflow"
      bucketAccountID     = "000000000000"
      bucketAccessRoleARN = "arn:aws:iam::000000000000:role/stub"
      notificationsSQSOptions = {
        region              = "us-east-1"
        assumeRoleAccountID = "000000000000"
        overrideQueueURL    = "https://sqs.us-east-1.amazonaws.com/000000000000/stub"
      }
    }
  })
}

# --- Outputs ----------------------------------------------------------------

output "aws_role_arn" {
  description = "ARN of the IAM role Wiz assumes to scan the account."
  value       = data.terraform_remote_state.wiz_iam.outputs.role_arn
}

output "aws_connector_id" {
  description = "Wiz connector ID (visible in the Wiz UI)."
  value       = wiz-v2_generic_connector.aws_sorcery.id
}

output "aws_connector_name" {
  description = "Wiz connector display name."
  value       = wiz-v2_generic_connector.aws_sorcery.name
}

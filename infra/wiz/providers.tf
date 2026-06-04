# =============================================================================
# AWS Provider Configuration
# =============================================================================

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "code-challenge-wiz-connector"
      Environment = terraform.workspace
      ManagedBy   = "Terraform"
      owner       = var.owner
      extend      = "true"
    }
  }
}

# =============================================================================
# Wiz v2 Provider Configuration
# =============================================================================
#
# Provider source: tf.app.wiz.io/wizsec/wiz-v2 (private registry).
# `terraform login tf.app.wiz.io` may be required before first init, depending
# on the registry's auth setup.

provider "wiz-v2" {
  env           = var.wiz_env
  client_id     = var.wiz_client_id
  client_secret = var.wiz_client_secret
}

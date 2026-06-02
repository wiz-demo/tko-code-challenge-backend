# Look up the tenant ID via the Wiz GraphQL API. Used as the external-id
# bound to the IAM role's trust policy, so only this specific Wiz tenant
# (not any other Wiz customer in the same data center) can assume the role.
data "wiz-v2_graphql_query" "me" {
  query = <<-EOQ
    query {
      viewerV2 {
        tenant { id }
      }
    }
  EOQ
}

locals {
  tenant_id = jsondecode(data.wiz-v2_graphql_query.me.result).viewerV2.tenant.id
}

# Wiz's published terraform module: provisions the customer IAM role with a
# trust policy bound to (wiz_remote_arn, external-id=tenant_id) and attaches
# the AWS-managed + Wiz-custom policies needed for the AWS connector.
module "wiz" {
  source                    = "https://wizio-public.s3.amazonaws.com/deployment-v3/aws/terraform/2527/wiz-aws-native-terraform-terraform-module.zip"
  external-id               = local.tenant_id
  data-scanning             = true
  lightsail-scanning        = false
  eks-scanning              = false
  remote-arn                = var.wiz_remote_arn
  terraform-bucket-scanning = true
  cloud-cost-scanning       = false
  rolename                  = var.wiz_role_name
  iam_policy_suffix         = var.iam_policy_suffix
}

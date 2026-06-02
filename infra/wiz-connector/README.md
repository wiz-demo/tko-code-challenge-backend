# Wiz AWS Connector (Terraform)

Provisions a Wiz AWS connector targeting AWS account `800618367342` via the
`wiz-v2` Terraform provider, and the IAM role Wiz assumes to scan the account.

Adapted from the `terraform-test` reference repo. Two-stage apply: the IAM
role is created first by a sub-module, then the connector resource consumes
the role ARN.

## Prerequisites

- Terraform `>= 1.10.0`
- AWS CLI v2 with SSO configured for profile `dev-product-cto-play`
- A Wiz service account (Wiz Console → Settings → Service Accounts) with at
  least `create:connectors` and `read:tenant` scopes
- Access to the Wiz private Terraform registry at `tf.app.wiz.io`
  (`terraform login tf.app.wiz.io` if `terraform init` prompts)

## First-time setup

```bash
cd infra/wiz-connector

# Fill in your Wiz secrets locally (file is gitignored — secrets won't be committed)
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# AWS SSO
aws sso login --profile dev-product-cto-play
```

## Apply

```bash
make init    # init both sub-projects
make plan    # plan both
make apply   # IAM first, then connector
```

After apply, check the Wiz UI under Settings → Connectors → the connector
`TF-AWS-Connector-SorcerySolutions` should appear and start its first scan
within a few minutes.

## Tear down

```bash
make destroy   # destroys connector first, then IAM role
```

## Layout

```
infra/wiz-connector/
├── versions.tf, providers.tf, variables.tf      Root module
├── connector_aws.tf                             wiz-v2_generic_connector resource
├── terraform.tfvars.example                     Reference values (no secrets)
├── terraform.tfvars                             Local-only, gitignored
├── Makefile                                     init / plan / apply / destroy
└── wiz-iam/
    ├── versions.tf, providers.tf, variables.tf  Sub-module
    ├── main.tf                                  Wiz's published IAM module
    └── outputs.tf                               Exposes role_arn
```

The root module reads the IAM role ARN from `wiz-iam/terraform.tfstate` via
`terraform_remote_state`. This is a deliberate workaround for a `wiz-v2`
provider bug where `customerRoleARN` referencing an unknown-after-apply value
triggers an `auth_params_hash__` inconsistency error.

## Things this won't do

- Does NOT scan account `432513806796` (the `cto-experts` profile's account)
- Does NOT modify the EKS deployment from `infra/terraform/`
- Does NOT configure Bedrock, DocumentDB, or any other supporting service

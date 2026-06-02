# EKS Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the FastAPI demo backend (with intentional CWE-78/89/502 vulnerabilities) to a fresh EKS Auto Mode cluster in AWS account `800618367342` (`cto-experts` SSO profile, `us-east-1`) via Terraform, exposed via a public NLB.

**Architecture:** Single Terraform module at `infra/aws/` with local state. One VPC, one EKS Auto Mode cluster, one ECR repo, one `null_resource`-style image build (`terraform_data`), one helm_release of the existing `helm/sorcery-solutions-backend` chart. Public exposure via Service type=LoadBalancer (NLB). No HTTPS, no backing services for Mongo/Bedrock.

**Tech Stack:** Terraform `>= 1.6`, `hashicorp/aws ~> 5.70`, `hashicorp/helm ~> 2.15`, `hashicorp/kubernetes ~> 2.32`, `hashicorp/external ~> 2.3`, `hashicorp/null ~> 3.2`. Docker + buildx locally for image builds. AWS CLI v2 for SSO.

**Spec:** [docs/superpowers/specs/2026-06-02-eks-deploy-design.md](../specs/2026-06-02-eks-deploy-design.md)

**Branch:** `feat/eks-deploy` (already checked out, cut from `feat/sql-injection-demo`).

**Note on testing:** Terraform code is verified per task with `terraform fmt` + `terraform validate`. The final end-to-end test is `terraform plan` (requires AWS auth) and `terraform apply` (creates real cloud resources). There is no automated unit-test layer for IaC in this plan — verification is structural (validate) and operational (apply + curl).

**Local prerequisites (operator's machine):**

```bash
# AWS CLI v2 with SSO session (token expires every few hours)
aws sso login --profile cto-experts

# Terraform 1.6+
terraform version

# Docker with buildx (Docker Desktop ships it by default)
docker buildx version

# kubectl (for post-apply verification only)
kubectl version --client
```

---

## Task 1: Fix the stale liveness/readiness probes in the helm chart

The chart currently probes `/api/spells`, which doesn't exist (the app's endpoints are `/api/prompts`, `/api/users`, `/api/execute`, `/api/import_prompts`, `/api/chat`). A deployment as-is would crash-loop on readiness. Fix the chart defaults to probe `/openapi.json`, which FastAPI always serves with HTTP 200.

**Files:**
- Modify: `helm/sorcery-solutions-backend/values.yaml` (lines 79–86)

- [ ] **Step 1: Confirm starting state**

```bash
grep -n 'api/spells\|openapi' helm/sorcery-solutions-backend/values.yaml
```

Expected: two matches for `path: /api/spells` (lines 81 and 85). No matches for `openapi`.

- [ ] **Step 2: Replace both probe paths**

In `helm/sorcery-solutions-backend/values.yaml`, change both occurrences of:

```yaml
    path: /api/spells
```

to:

```yaml
    path: /openapi.json
```

(Both `livenessProbe.httpGet.path` and `readinessProbe.httpGet.path`. Use a single `replace_all` with the Edit tool to do both at once.)

- [ ] **Step 3: Verify the change**

```bash
grep -n 'api/spells\|openapi' helm/sorcery-solutions-backend/values.yaml
```

Expected: two matches for `path: /openapi.json` (lines 81 and 85). No matches for `api/spells`.

- [ ] **Step 4: Commit**

```bash
git add helm/sorcery-solutions-backend/values.yaml
git commit -m "fix(helm): probe /openapi.json instead of nonexistent /api/spells

The /api/spells endpoint doesn't exist in the FastAPI app, so the
default chart values cause pods to crash-loop on readiness. Switch
to /openapi.json which FastAPI always serves with HTTP 200."
```

---

## Task 2: Terraform module scaffolding

Bootstrap `infra/aws/` with provider config, required-providers pins, variables, default_tags, and a `.gitignore` so state and provider plugins don't get committed.

**Files:**
- Create: `infra/aws/.gitignore`
- Create: `infra/aws/versions.tf`
- Create: `infra/aws/main.tf`
- Create: `infra/aws/variables.tf`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p infra/aws
```

- [ ] **Step 2: Create `infra/aws/.gitignore`**

```gitignore
# Terraform state and lock files
*.tfstate
*.tfstate.*
*.tfstate.backup
crash.log
crash.*.log

# Terraform provider plugins and modules
.terraform/
.terraform.lock.hcl

# Plan files
*.tfplan
```

- [ ] **Step 3: Create `infra/aws/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

- [ ] **Step 4: Create `infra/aws/variables.tf`**

```hcl
variable "region" {
  type        = string
  description = "AWS region. Must be one of the SCP-allowed regions."
  default     = "us-east-1"
  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2"], var.region)
    error_message = "Region must be us-east-1, us-east-2, or us-west-2 (SCP-allowed)."
  }
}

variable "aws_profile" {
  type        = string
  description = "AWS CLI profile (SSO). Per project CLAUDE.md."
  default     = "cto-experts"
}

variable "owner" {
  type        = string
  description = "Required `owner` tag value. Per CLAUDE.md, mandatory on most resources."
  default     = "itay.katz"
}

variable "project" {
  type        = string
  description = "Project tag for cost attribution."
  default     = "sorcery-solutions-eks-demo"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name."
  default     = "sorcery-demo"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS control-plane Kubernetes version."
  default     = "1.32"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block."
  default     = "10.42.0.0/16"
}
```

- [ ] **Step 5: Create `infra/aws/main.tf`**

```hcl
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      owner   = var.owner
      project = var.project
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
```

- [ ] **Step 6: Initialise and validate**

```bash
terraform -chdir=infra/aws init -input=false
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `init` downloads all 5 providers, `fmt` reports no changes (or reformats — that's fine, just re-stage), `validate` prints `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add infra/aws/.gitignore infra/aws/versions.tf infra/aws/main.tf infra/aws/variables.tf
git commit -m "feat(infra): scaffold Terraform module for EKS deploy

Adds provider pins, AWS provider config with default_tags
(owner + project per CLAUDE.md), variables, .gitignore for
state files. terraform init/validate succeed."
```

---

## Task 3: VPC with 2 public + 2 private subnets, IGW, single NAT

Self-contained networking. EKS Auto Mode needs both public subnets (tagged `kubernetes.io/role/elb=1` so the LB controller will place internet-facing LBs there) and private subnets (tagged `internal-elb` for pods).

**Files:**
- Create: `infra/aws/vpc.tf`

- [ ] **Step 1: Create `infra/aws/vpc.tf`**

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# Public subnets (one per AZ): for the public NLB
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)        # /20 starting at .0.0
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                              = "${var.cluster_name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                          = "1"
    "kubernetes.io/cluster/${var.cluster_name}"       = "shared"
  }
}

# Private subnets (one per AZ): for pods
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 2)          # /20 starting at .32.0
  availability_zone = local.azs[count.index]

  tags = {
    Name                                              = "${var.cluster_name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"                 = "1"
    "kubernetes.io/cluster/${var.cluster_name}"       = "shared"
  }
}

# Single NAT in public subnet 0 (cost-saving — not multi-AZ-NAT)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "${var.cluster_name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-rt-private"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add infra/aws/vpc.tf
git commit -m "feat(infra): add VPC with 2 public + 2 private subnets

Single VPC at 10.42.0.0/16 spanning 2 AZs. Public subnets tagged
for ELB placement, private subnets tagged for internal ELB (pod
placement). Single NAT gateway in public AZ-a (cost-saving)."
```

---

## Task 4: ECR repository for the backend image

**Files:**
- Create: `infra/aws/ecr.tf`

- [ ] **Step 1: Create `infra/aws/ecr.tf`**

```hcl
resource "aws_ecr_repository" "backend" {
  name                 = "sorcery-solutions-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "sorcery-solutions-backend"
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add infra/aws/ecr.tf
git commit -m "feat(infra): add ECR repo for backend image

Mutable tags (so re-builds at the same git SHA work during
iteration), scan-on-push, force_delete so terraform destroy
doesn't error on residual images, lifecycle policy retains
5 most recent images."
```

---

## Task 5: EKS Auto Mode cluster

The biggest single file in the module. Defines the cluster IAM role, the node IAM role (used by Auto Mode), the cluster itself with `compute_config` / `kubernetes_network_config` / `storage_config`, and an access entry that grants cluster admin to whoever ran `terraform apply` (resolved from `data.aws_caller_identity` with SSO-assumed-role normalisation).

**Files:**
- Create: `infra/aws/eks.tf`

- [ ] **Step 1: Create `infra/aws/eks.tf`**

```hcl
# ----- Cluster IAM role -----
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Auto Mode requires this exact set of managed policies on the cluster role
resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.cluster.name
}

# ----- Node IAM role (used by Auto Mode-managed nodes) -----
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Minimal policy set — pull-only ECR + the worker minimum. NO additional
# AWS API access, so an RCE inside the pod can't trivially pivot to AWS.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  policy_arn = each.value
  role       = aws_iam_role.node.name
}

# ----- EKS cluster (Auto Mode) -----
resource "aws_eks_cluster" "this" {
  name                          = var.cluster_name
  version                       = var.kubernetes_version
  role_arn                      = aws_iam_role.cluster.arn
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API"
  }

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy_attachment.node,
  ]
}

# ----- Cluster-admin access entry for the operator -----
# data.aws_caller_identity.current.arn for SSO sessions returns an
# assumed-role ARN like:
#   arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>
# EKS access entries need the role ARN, which for SSO is:
#   arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/<RoleName>
# This locals block converts when running under SSO and falls back to the
# raw caller ARN otherwise (regular IAM user / role).
locals {
  _caller_arn        = data.aws_caller_identity.current.arn
  _is_assumed_role   = startswith(local._caller_arn, "arn:aws:sts::")
  _assumed_role_name = local._is_assumed_role ? split("/", local._caller_arn)[1] : ""
  _is_sso            = local._is_assumed_role && startswith(local._assumed_role_name, "AWSReservedSSO_")

  admin_principal_arn = local._is_sso ? (
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/${local._assumed_role_name}"
  ) : local._caller_arn
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.admin_principal_arn
  policy_arn    = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add infra/aws/eks.tf
git commit -m "feat(infra): add EKS Auto Mode cluster + IAM + access entry

Cluster IAM role with the Auto Mode managed-policy set. Node IAM
role with pull-only ECR + worker minimum (no extra AWS permissions
so a pod RCE can't pivot via the node). Cluster runs k8s 1.32 with
compute, networking, and storage all in Auto Mode. Caller (resolved
from SSO assumed-role ARN) gets cluster-admin access entry."
```

---

## Task 6: Image build via `terraform_data` + `local-exec`

A `terraform_data` resource whose `triggers_replace` map includes the git SHA and the Dockerfile hash. When either changes, the `local-exec` re-runs `docker buildx build --push`. Uses `data "external"` to read the git SHA at plan time.

**Files:**
- Create: `infra/aws/image.tf`

- [ ] **Step 1: Create `infra/aws/image.tf`**

```hcl
# Read git SHA at plan time so it lands in the image tag
data "external" "git_sha" {
  program = ["sh", "-c", "printf '{\"sha\":\"%s\"}' \"$(git rev-parse --short=12 HEAD)\""]
}

# Hash of every file under app/ so app changes trigger a rebuild
locals {
  _app_files = fileset("${path.module}/../../app", "**")
  app_sha = sha256(join(",", [
    for f in local._app_files :
    filesha256("${path.module}/../../app/${f}")
  ]))
  dockerfile_sha = filesha256("${path.module}/../../docker/debian/Dockerfile")
  image_tag      = data.external.git_sha.result.sha
  image_uri      = "${aws_ecr_repository.backend.repository_url}:${local.image_tag}"
}

resource "terraform_data" "image_build" {
  triggers_replace = {
    image_tag      = local.image_tag
    dockerfile_sha = local.dockerfile_sha
    app_sha        = local.app_sha
    repository_url = aws_ecr_repository.backend.repository_url
  }

  provisioner "local-exec" {
    # buildx is required for --platform; --provenance=false is required
    # because ECR rejects OCI provenance attestations as "unsupported
    # media type". Build context is the repo root because the Dockerfile
    # COPYs from ../../app relative to its own location.
    command     = <<-EOT
      set -euo pipefail
      aws ecr get-login-password --region ${var.region} --profile ${var.aws_profile} \
        | docker login --username AWS --password-stdin ${aws_ecr_repository.backend.repository_url}
      docker buildx build \
        --platform linux/amd64 \
        --provenance=false \
        --file ${path.module}/../../docker/debian/Dockerfile \
        --tag ${local.image_uri} \
        --push \
        ${path.module}/../..
    EOT
    interpreter = ["bash", "-c"]
  }
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `Success! The configuration is valid.` (validate doesn't run the local-exec; it just checks syntax.)

- [ ] **Step 3: Commit**

```bash
git add infra/aws/image.tf
git commit -m "feat(infra): build and push backend image to ECR via local-exec

terraform_data resource with triggers_replace on git SHA, the
Dockerfile hash, and a rolled-up hash of every file under app/.
Uses docker buildx with --platform linux/amd64 (Apple Silicon
operators need buildx; Docker Desktop ships it). --provenance=false
because ECR rejects OCI provenance attestations."
```

---

## Task 7: Helm release of the backend chart

Configures the helm and kubernetes providers using `data.aws_eks_cluster_auth`, deploys the existing `helm/sorcery-solutions-backend` chart with overrides for image, service type, env vars, and resources. The probe paths come from the chart defaults (fixed in Task 1).

**Files:**
- Create: `infra/aws/k8s.tf`

- [ ] **Step 1: Create `infra/aws/k8s.tf`**

```hcl
data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

resource "helm_release" "backend" {
  name      = "sorcery-solutions-backend"
  chart     = "${path.module}/../../helm/sorcery-solutions-backend"
  namespace = "default"

  values = [
    yamlencode({
      image = {
        repository = aws_ecr_repository.backend.repository_url
        tag        = local.image_tag
        pullPolicy = "IfNotPresent"
      }
      service = {
        type = "LoadBalancer"
        port = 8000
      }
      env = {
        MONGO_URI = "mongodb://placeholder:27017"
        MONGO_DB  = "sorcery_demo"
      }
      resources = {
        requests = {
          cpu    = "250m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    })
  ]

  wait    = true
  timeout = 600

  depends_on = [
    terraform_data.image_build,
    aws_eks_access_policy_association.admin,
  ]
}

# Read the Service after helm_release applies so we can output the NLB hostname
data "kubernetes_service" "backend" {
  metadata {
    name      = helm_release.backend.name
    namespace = helm_release.backend.namespace
  }
}
```

- [ ] **Step 2: Format and validate**

```bash
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add infra/aws/k8s.tf
git commit -m "feat(infra): helm_release of sorcery-solutions-backend chart

Helm and kubernetes providers wired to the EKS cluster via
data.aws_eks_cluster_auth token. Chart values override image
(ECR repo + git SHA from image.tf), service.type=LoadBalancer
(so AWS LB Controller in Auto Mode provisions an NLB), placeholder
Mongo env, and conservative resource requests/limits. wait=true
blocks apply until the pod is healthy."
```

---

## Task 8: Outputs + Makefile

Operator-facing surface: kubeconfig command, ECR URL, NLB hostname (or graceful empty if not yet provisioned), pre-baked smoke-test commands. Makefile shortcuts.

**Files:**
- Create: `infra/aws/outputs.tf`
- Create: `infra/aws/Makefile`

- [ ] **Step 1: Create `infra/aws/outputs.tf`**

```hcl
output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "region" {
  value = var.region
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "image_uri" {
  value = local.image_uri
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name} --profile ${var.aws_profile}"
}

output "service_hostname" {
  description = "Public NLB hostname. May be empty for ~60s after apply while AWS provisions the LB; re-run 'terraform refresh' or 'make outputs'."
  value = try(
    data.kubernetes_service.backend.status[0].load_balancer[0].ingress[0].hostname,
    "(not yet ready — re-run 'terraform refresh && terraform output')"
  )
}

output "smoke_test_commands" {
  description = "Curl commands to verify the deploy. Run 'terraform output -raw smoke_test_commands' to get an unquoted version."
  value = try(
    join("\n", [
      "# benign",
      "curl -s 'http://${data.kubernetes_service.backend.status[0].load_balancer[0].ingress[0].hostname}/api/users?username=alice'",
      "",
      "# SQL injection exploit (returns all 3 rows)",
      "curl -s --get 'http://${data.kubernetes_service.backend.status[0].load_balancer[0].ingress[0].hostname}/api/users' --data-urlencode \"username=' OR '1'='1\"",
    ]),
    "(NLB not yet ready)"
  )
}
```

- [ ] **Step 2: Create `infra/aws/Makefile`**

```makefile
SHELL := /bin/bash
TF    := terraform

.PHONY: help init fmt validate plan apply destroy outputs kubeconfig smoke

help:
	@echo "Targets:"
	@echo "  init        - terraform init"
	@echo "  fmt         - terraform fmt"
	@echo "  validate    - terraform validate"
	@echo "  plan        - terraform plan (requires SSO: aws sso login --profile cto-experts)"
	@echo "  apply       - terraform apply (requires SSO)"
	@echo "  destroy     - terraform destroy (requires SSO)"
	@echo "  outputs     - refresh state and print outputs"
	@echo "  kubeconfig  - write the cluster context into your kubeconfig"
	@echo "  smoke       - hit the deployed endpoint with benign + exploit payloads"

init:
	$(TF) init -input=false

fmt:
	$(TF) fmt

validate:
	$(TF) validate

plan:
	$(TF) plan

apply:
	$(TF) apply

destroy:
	$(TF) destroy

outputs:
	$(TF) refresh > /dev/null
	$(TF) output

kubeconfig:
	@eval "$$($(TF) output -raw kubeconfig_command)"

smoke:
	@$(TF) refresh > /dev/null
	@eval "$$($(TF) output -raw smoke_test_commands)"
```

- [ ] **Step 3: Format and validate**

```bash
terraform -chdir=infra/aws fmt
terraform -chdir=infra/aws validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

(Skip `terraform plan` at this point — on a fresh apply, `data.kubernetes_service.backend` in `outputs.tf` cannot resolve because the cluster doesn't exist yet, so plan will error. This is handled by the staged apply in Task 9 Step 2.)

```bash
git add infra/aws/outputs.tf infra/aws/Makefile
git commit -m "feat(infra): outputs + Makefile convenience wrappers

Outputs expose cluster name, region, ECR URL, image URI, the
kubeconfig command, the NLB hostname (or graceful empty), and
pre-baked smoke-test curl commands. Makefile wraps the common
flows (init/plan/apply/destroy + kubeconfig + smoke)."
```

---

## Task 9: End-to-end deploy and verification

This is the operator action: run apply, watch it, verify with kubectl + curl. No commit at the end — the deploy itself is ephemeral state.

**Files:** none modified.

- [ ] **Step 1: Ensure SSO is active**

```bash
aws sts get-caller-identity --profile cto-experts --region us-east-1
```

Expected: `Account: 800618367342`, `Arn: arn:aws:sts::800618367342:assumed-role/AWSReservedSSO_<role>/<session>`.

If you see "Token has expired and refresh failed", run:

```bash
aws sso login --profile cto-experts
```

- [ ] **Step 2: Staged apply — cluster first, then helm**

The `data.kubernetes_service.backend` in `outputs.tf` reads the Service at refresh time. On a fresh apply, the cluster doesn't exist yet, so that data source can't resolve and `terraform plan` may error. The standard workaround is a two-stage apply.

```bash
cd infra/aws

# Stage 1: build everything except the helm release + kubernetes data source
terraform apply \
  -target=aws_eks_cluster.this \
  -target=aws_eks_access_policy_association.admin \
  -target=terraform_data.image_build
```

Expected: ~15 minutes (EKS control plane is the long pole). Confirms with `Apply complete! Resources: ~25 added, 0 changed, 0 destroyed.`

```bash
# Stage 2: helm + the kubernetes data source
terraform apply
```

Expected: ~3 minutes (helm install + NLB provisioning). Confirms with `Apply complete!` and outputs print.

- [ ] **Step 3: Wait for the NLB to be reachable**

```bash
HOSTNAME=$(terraform output -raw service_hostname)
echo "NLB hostname: $HOSTNAME"

# DNS + LB provisioning can take 60–120s after apply finishes
until curl -sf "http://$HOSTNAME/openapi.json" > /dev/null; do
  echo "Waiting for NLB to accept traffic..."
  sleep 10
done
echo "NLB is responding."
```

- [ ] **Step 4: Verify with kubectl**

```bash
eval "$(terraform output -raw kubeconfig_command)"
kubectl get pods -n default -l app.kubernetes.io/name=sorcery-solutions-backend
```

Expected: one pod in `Running` state with `READY 1/1`.

```bash
kubectl get svc sorcery-solutions-backend -n default -o wide
```

Expected: `TYPE` is `LoadBalancer`, `EXTERNAL-IP` is the NLB hostname.

- [ ] **Step 5: Smoke-test the endpoints**

```bash
make smoke
```

Expected output (interleaved):

```
[{"id":1,"username":"alice","email":"alice@example.com","role":"user"}]

[{"id":1,"username":"alice","email":"alice@example.com","role":"user"},{"id":2,"username":"bob","email":"bob@example.com","role":"user"},{"id":3,"username":"admin","email":"admin@sorcery.example","role":"admin"}]
```

The first line is the benign lookup. The second line is the SQL-injection payload returning all three rows — confirming CWE-89 is live and exploitable on the public internet.

- [ ] **Step 6: Capture deploy summary in the conversation (no commit)**

Report back with:
- The NLB hostname.
- The cluster name (from `terraform output cluster_name`).
- Confirmation that both smoke-test outputs (benign + exploit) matched expected.
- The estimated cost-while-running and the date by which the SCP cleanup would delete this (today + 30 days).

---

## Done criteria

- [ ] All 8 tracked commits land on `feat/eks-deploy`.
- [ ] `infra/aws/` contains the 9 files listed above (plus `.terraform.lock.hcl`, which the `.gitignore` excludes).
- [ ] `terraform apply` succeeds end-to-end.
- [ ] `curl http://<nlb-hostname>/api/users?username=alice` returns alice's row.
- [ ] `curl --get 'http://<nlb-hostname>/api/users' --data-urlencode "username=' OR '1'='1"` returns all three rows.
- [ ] `kubectl get pods` shows backend pod Running.
- [ ] No changes outside `infra/aws/` and `helm/sorcery-solutions-backend/values.yaml` (and the plan/spec docs already committed).

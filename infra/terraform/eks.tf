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
# EKS access entries need the underlying IAM role ARN. For SSO the path
# includes a region segment (e.g. /aws-reserved/sso.amazonaws.com/us-east-2/)
# that can't be derived from the caller ARN, so we look it up via
# data.aws_iam_roles. For regular assumed roles we construct the ARN
# directly. For IAM users we use the caller ARN unchanged.
locals {
  _caller_arn        = data.aws_caller_identity.current.arn
  _is_assumed_role   = startswith(local._caller_arn, "arn:aws:sts::")
  _assumed_role_name = local._is_assumed_role ? split("/", local._caller_arn)[1] : ""
  _is_sso            = local._is_assumed_role && startswith(local._assumed_role_name, "AWSReservedSSO_")
}

data "aws_iam_roles" "sso_admin" {
  count       = local._is_sso ? 1 : 0
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
  name_regex  = "^${local._assumed_role_name}$"
}

locals {
  admin_principal_arn = local._is_sso ? (
    one(tolist(data.aws_iam_roles.sso_admin[0].arns))
    ) : local._is_assumed_role ? (
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local._assumed_role_name}"
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

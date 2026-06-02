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
  description = "AWS CLI profile (SSO) for account 800618367342. Verified via `aws sts get-caller-identity --profile <name>`."
  default     = "dev-product-cto-play"
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

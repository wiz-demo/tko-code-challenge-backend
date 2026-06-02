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

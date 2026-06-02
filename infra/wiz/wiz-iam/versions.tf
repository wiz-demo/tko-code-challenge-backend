terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    wiz-v2 = {
      source = "tf.app.wiz.io/wizsec/wiz-v2"
    }
  }
}

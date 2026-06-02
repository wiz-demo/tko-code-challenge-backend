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

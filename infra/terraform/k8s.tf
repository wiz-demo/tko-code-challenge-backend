provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", aws_eks_cluster.this.name,
        "--region", var.region,
        "--profile", var.aws_profile,
      ]
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", aws_eks_cluster.this.name,
      "--region", var.region,
      "--profile", var.aws_profile,
    ]
  }
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
      }
      service = {
        type = "LoadBalancer"
        port = 8000
      }
      # Chart's deployment.yaml does `toYaml .Values.env` and Kubernetes
      # Container.env requires a list of {name, value} pairs (not a map),
      # so pass env as a list here. The chart's default values.yaml has
      # the same map shape and is broken — only the override saves us.
      env = [
        { name = "MONGO_URI", value = "mongodb://placeholder:27017" },
        { name = "MONGO_DB", value = "sorcery_demo" },
      ]
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

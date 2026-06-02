# Read git SHA at plan time so it lands in the image tag
data "external" "git_sha" {
  program = ["sh", "-c", "printf '{\"sha\":\"%s\"}' \"$(git rev-parse --short=12 HEAD)\""]
}

# Hash of every file under app/ so app changes trigger a rebuild
locals {
  _app_files = [for f in fileset("${path.module}/../../app", "**") : f if !can(regex("__pycache__", f)) && !endswith(f, ".pyc")]
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

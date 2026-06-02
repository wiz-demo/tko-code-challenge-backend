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

# Look up the ASG-launched instance after apply so we can return its public IP.
# Returns an empty list (handled by try()) if the instance hasn't booted yet.
data "aws_instances" "backend" {
  instance_tags = {
    Name = "code-challenge-backend"
  }

  instance_state_names = ["running"]

  depends_on = [aws_autoscaling_group.ecs]
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
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

output "instance_public_ip" {
  description = "Public IP of the ECS EC2 host. May be empty for ~2 min after apply while the ASG instance boots and registers. Re-run 'make outputs' if empty."
  value       = try(data.aws_instances.backend.public_ips[0], "(instance not yet running)")
}

output "smoke_test_commands" {
  description = "Curl commands to verify the deploy. Run 'terraform output -raw smoke_test_commands' for an unquoted version."
  value = try(
    join("\n", [
      "# sample root",
      "curl -s 'http://${data.aws_instances.backend.public_ips[0]}:8000/'",
      "",
      "# benign SQLi endpoint",
      "curl -s 'http://${data.aws_instances.backend.public_ips[0]}:8000/api/users?username=alice'",
      "",
      "# SQL injection exploit (returns all 3 rows)",
      "curl -s --get 'http://${data.aws_instances.backend.public_ips[0]}:8000/api/users' --data-urlencode \"username=' OR '1'='1\"",
      "",
      "# Command injection",
      "curl -s 'http://${data.aws_instances.backend.public_ips[0]}:8000/api/execute?command=id'",
    ]),
    "(instance not yet running)"
  )
}

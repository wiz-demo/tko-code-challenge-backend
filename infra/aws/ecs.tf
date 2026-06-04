resource "aws_ecs_cluster" "this" {
  name = var.ecs_cluster_name
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.this.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
    base              = 1
  }
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/code-challenge-backend"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "code-challenge-backend"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name      = "backend"
    image     = local.image_uri
    essential = true
    cpu       = 256
    memory    = 512
    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.backend.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])

  # Ensure the image exists in ECR before the task definition is created
  depends_on = [terraform_data.image_build]
}

resource "aws_ecs_service" "backend" {
  name            = "backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 1

  # Single-task service on a single instance with hostPort=8000 means we
  # can't run two tasks simultaneously (port conflict). Allow stopping the
  # old task before starting the new one.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
    base              = 1
  }

  # The capacity provider must be associated with the cluster before the
  # service can use it.
  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

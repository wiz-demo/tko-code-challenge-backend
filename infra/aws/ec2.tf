# ECS-optimized Amazon Linux 2023 AMI (region-aware via the provider)
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_security_group" "backend" {
  name        = "code-challenge-backend"
  description = "Allow public access on 8000 to ECS container host"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "App port 8000 from anywhere (mirrors prior internet-facing ELB)"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress (ECR pull, CloudWatch Logs, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "code-challenge-backend"
  }
}

resource "aws_launch_template" "ecs" {
  name_prefix   = "code-challenge-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = "t3.large"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  vpc_security_group_ids = [aws_security_group.backend.id]

  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.this.name} >> /etc/ecs/ecs.config
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "code-challenge-backend"
    }
  }
}

resource "aws_autoscaling_group" "ecs" {
  name_prefix      = "code-challenge-"
  desired_capacity = 1
  min_size         = 1
  max_size         = 1

  vpc_zone_identifier = [aws_subnet.public[0].id]

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  # Required for the ECS capacity provider to manage the ASG
  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  # Required project tags (per CLAUDE.md). default_tags on the provider does
  # NOT propagate to ASG-launched instances, so set them explicitly.
  tag {
    key                 = "owner"
    value               = var.owner
    propagate_at_launch = true
  }

  tag {
    key                 = "extend"
    value               = "true"
    propagate_at_launch = true
  }
}

resource "aws_ecs_capacity_provider" "this" {
  name = "code-challenge-ec2"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }
  }
}

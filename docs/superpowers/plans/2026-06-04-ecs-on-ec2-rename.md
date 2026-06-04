# ECS-on-EC2 + sorcery → code-challenge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace EKS+Helm with a minimal ECS-on-EC2 deploy, trim the FastAPI app to two intentional-vuln endpoints + a sample root, and rename every occurrence of `sorcery` to `code-challenge` across the repo.

**Architecture:** Single ECS cluster `code-challenge`, one EC2 instance from an ASG (desired=1) running the ECS-optimized Amazon Linux 2023 AMI, one task definition pulling the container image from ECR (`code-challenge-backend`), one ECS service. Public ingress on `:8000` directly to the instance via security group. Shell access via SSM Session Manager (no SSH). Image build pipeline (`image.tf`) unchanged.

**Tech Stack:** Terraform (AWS provider only — Helm/Kubernetes providers removed), Amazon ECS on EC2, ECR, ECS-optimized AL2023 AMI, FastAPI (Python 3.12), Docker.

**Spec:** `docs/superpowers/specs/2026-06-04-ecs-on-ec2-rename-design.md`

---

## Task 1: Trim FastAPI app to final endpoint surface

**Files:**
- Modify: `app/main.py` (full rewrite)
- Modify: `app/database.py` (full rewrite, no rename yet — that's Task 8)
- Delete: `app/schemas.py`
- Delete: `app/models.py`
- Modify: `app/requirements.txt`

- [ ] **Step 1: Rewrite `app/main.py`**

Replace the entire file contents with:

```python
import logging
import subprocess

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from database import sqlite_db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root():
    return {"name": "code-challenge-backend", "message": "sample text"}


@app.get("/api/users")
async def get_users(username: str | None = None):
    # Vulnerable to SQL injection (CWE-89) — intentional for demo
    query = f"SELECT id, username, email, role FROM users WHERE username = '{username}'"
    rows = sqlite_db.execute(query).fetchall()
    return [
        {"id": r[0], "username": r[1], "email": r[2], "role": r[3]}
        for r in rows
    ]


@app.get("/api/execute")
async def execute_command(command: str | None = None):
    process = subprocess.Popen(
        command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout = process.stdout.read().decode()
    stderr = process.stderr.read().decode()
    return {"stdout": stdout, "stderr": stderr}
```

- [ ] **Step 2: Rewrite `app/database.py`**

Replace the entire file contents with (no rename — the email keeps `@sorcery.example` for now; Task 8 renames it):

```python
import sqlite3

# In-memory sqlite users table used by the intentionally vulnerable
# /api/users endpoint (CWE-89 demo). Connection is shared across uvicorn
# worker threads, so check_same_thread must be False.
sqlite_db = sqlite3.connect(":memory:", check_same_thread=False)
sqlite_db.execute(
    "CREATE TABLE users ("
    "id INTEGER PRIMARY KEY, "
    "username TEXT NOT NULL, "
    "email TEXT NOT NULL, "
    "role TEXT NOT NULL"
    ")"
)
sqlite_db.executemany(
    "INSERT INTO users (id, username, email, role) VALUES (?, ?, ?, ?)",
    [
        (1, "alice", "alice@example.com", "user"),
        (2, "bob", "bob@example.com", "user"),
        (3, "admin", "admin@sorcery.example", "admin"),
    ],
)
sqlite_db.commit()
```

- [ ] **Step 3: Delete `app/schemas.py` and `app/models.py`**

```bash
rm app/schemas.py app/models.py
```

- [ ] **Step 4: Trim `app/requirements.txt`**

Replace the entire file contents with:

```
fastapi[standard]~=0.115
uvicorn[standard]~=0.34
pydantic~=2.11
```

- [ ] **Step 5: Smoke-test locally**

```bash
cd app && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
uvicorn main:app --host 127.0.0.1 --port 8001 &
SERVER_PID=$!
sleep 2
curl -s http://127.0.0.1:8001/
curl -s 'http://127.0.0.1:8001/api/users?username=alice'
curl -s --get 'http://127.0.0.1:8001/api/users' --data-urlencode "username=' OR '1'='1"
curl -s 'http://127.0.0.1:8001/api/execute?command=id'
kill $SERVER_PID
deactivate
cd ..
```

Expected:
- `/` returns `{"name":"code-challenge-backend","message":"sample text"}`
- `/api/users?username=alice` returns 1 row
- The SQLi payload returns 3 rows
- `/api/execute?command=id` returns `{"stdout":"uid=...","stderr":""}`

If the venv approach feels heavy, install into the system Python interpreter, just verify the same 4 curls work.

- [ ] **Step 6: Commit**

```bash
git add app/
git commit -m "$(cat <<'EOF'
refactor(app): trim to sample root + SQLi + RCE endpoints

Drop Mongo (motor), Bedrock (boto3), and YAML deserialization endpoints.
Remaining surface: GET / (sample text), GET /api/users (SQLi demo),
GET /api/execute (RCE demo). schemas.py and models.py become empty after
the cuts so they are deleted.
EOF
)"
```

---

## Task 2: Phase 1 — destroy EKS resources (providers still defined)

**Files:** none — state-only changes.

**Rationale:** Removing `helm_release` from config while the kubernetes/helm providers point at a soon-to-be-deleted EKS cluster produces flaky "Unauthorized" errors at plan time. Targeted destroy first sidesteps it.

- [ ] **Step 1: Verify SSO logged in**

```bash
aws sts get-caller-identity --profile dev-product-cto-play
```

If this fails with token-expired, prompt the user to run `aws sso login --profile dev-product-cto-play` in their own terminal — Claude cannot run the interactive login.

- [ ] **Step 2: Targeted destroy of helm release + service data source**

```bash
cd infra/aws
terraform destroy \
  -target=helm_release.backend \
  -target=data.kubernetes_service.backend \
  -auto-approve
```

Expected: helm release `sorcery-solutions-backend` removed, ELB `a4df26972a50b4187b0bbcb0775f08cb` deleted (verify in console under EC2 → Load Balancers, region us-east-1).

- [ ] **Step 3: Targeted destroy of EKS cluster + node group + IAM**

```bash
terraform destroy \
  -target=aws_eks_access_policy_association.admin \
  -target=aws_eks_access_entry.admin \
  -target=aws_eks_node_group.general \
  -target=aws_eks_cluster.this \
  -target=aws_iam_role_policy_attachment.node \
  -target=aws_iam_role_policy_attachment.cluster \
  -target=aws_iam_role.node \
  -target=aws_iam_role.cluster \
  -auto-approve
```

Expected: EKS cluster `sorcery-demo`, node group `general`, both IAM roles destroyed. Takes ~10 minutes.

- [ ] **Step 4: Verify in AWS**

```bash
aws eks list-clusters --profile dev-product-cto-play --region us-east-1
aws elbv2 describe-load-balancers --profile dev-product-cto-play --region us-east-1 --query 'LoadBalancers[?contains(LoadBalancerName, `sorcery`)]' --output json
aws elb describe-load-balancers --profile dev-product-cto-play --region us-east-1 --query 'LoadBalancerDescriptions[?contains(LoadBalancerName, `a4df`)]' --output json
```

Expected: empty cluster list, empty arrays for both LB queries.

`cd ..` (back to repo root) when done.

No git commit — only state changed.

---

## Task 3: Remove EKS code, providers, and EKS-only VPC tags

**Files:**
- Delete: `infra/aws/eks.tf`
- Delete: `infra/aws/k8s.tf`
- Delete: `helm/sorcery-solutions-backend/` (entire directory)
- Modify: `infra/aws/versions.tf`
- Modify: `infra/aws/vpc.tf`
- Modify: `infra/aws/Makefile`

- [ ] **Step 1: Delete EKS Terraform files and Helm chart directory**

```bash
rm infra/aws/eks.tf infra/aws/k8s.tf
rm -rf helm/sorcery-solutions-backend
```

- [ ] **Step 2: Rewrite `infra/aws/versions.tf` to drop helm + kubernetes**

Replace entire file contents with:

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

- [ ] **Step 3: Edit `infra/aws/vpc.tf` — drop the `kubernetes.io/*` subnet tags**

Replace the `tags` block in `aws_subnet.public` (lines 27–32 of the original file) — remove the two `kubernetes.io/*` tags so it becomes:

```hcl
  tags = {
    Name = "${var.cluster_name}-public-${local.azs[count.index]}"
  }
```

Replace the `tags` block in `aws_subnet.private` — remove the two `kubernetes.io/*` tags so it becomes:

```hcl
  tags = {
    Name = "${var.cluster_name}-private-${local.azs[count.index]}"
  }
```

(All other lines in `vpc.tf` stay unchanged. The `var.cluster_name` reference will be renamed in Task 7 — leave it for now.)

- [ ] **Step 4: Edit `infra/aws/Makefile` — drop the `kubeconfig` target**

In `.PHONY:` line, remove `kubeconfig`. In the help block, delete the line describing `kubeconfig`. Delete the entire `kubeconfig:` target block (lines 40–41). The remaining targets (init, fmt, validate, plan, apply, destroy, outputs, smoke) stay as-is.

- [ ] **Step 5: Run terraform init to drop the old providers**

```bash
cd infra/aws
terraform init -upgrade
cd ..
```

Expected: terraform reports removal of `hashicorp/helm` and `hashicorp/kubernetes` providers.

- [ ] **Step 6: Commit**

```bash
git add infra/aws/ helm/
git commit -m "$(cat <<'EOF'
chore(infra): remove EKS terraform, helm chart, and k8s/helm providers

Phase 2a of the EKS → ECS migration. Deletes eks.tf, k8s.tf, the
sorcery-solutions-backend helm chart directory, drops the helm and
kubernetes provider declarations from versions.tf, removes the
EKS-specific kubernetes.io subnet tags from vpc.tf, and removes the
now-dead kubeconfig Makefile target.
EOF
)"
```

---

## Task 4: Add `infra/aws/iam.tf` (ECS roles)

**Files:**
- Create: `infra/aws/iam.tf`

- [ ] **Step 1: Create the file with both ECS IAM roles**

```hcl
# ----- EC2 instance role (ECS agent registration, ECR read, SSM) -----
resource "aws_iam_role" "ecs_instance" {
  name = "code-challenge-ecs-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.ecs_instance.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "code-challenge-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

# ----- ECS task execution role (pull image from ECR, write to CloudWatch Logs) -----
resource "aws_iam_role" "ecs_task_execution" {
  name = "code-challenge-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
```

- [ ] **Step 2: Validate**

```bash
cd infra/aws && terraform fmt iam.tf && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd ..
git add infra/aws/iam.tf
git commit -m "feat(infra): ECS instance and task execution IAM roles"
```

---

## Task 5: Add `infra/aws/ec2.tf` (security group + launch template + ASG + capacity provider)

**Files:**
- Create: `infra/aws/ec2.tf`

- [ ] **Step 1: Verify the ECS-optimized AL2023 AMI SSM parameter resolves**

```bash
aws ssm get-parameter \
  --name /aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id \
  --profile dev-product-cto-play --region us-east-1 \
  --query 'Parameter.Value' --output text
```

Expected: an `ami-...` ID. If this fails, stop and investigate — the launch template depends on it.

- [ ] **Step 2: Create `infra/aws/ec2.tf`**

```hcl
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
  instance_type = "t3.small"

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
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
```

- [ ] **Step 3: Format only (skip validate)**

```bash
cd infra/aws && terraform fmt ec2.tf && cd ..
```

Do NOT run `terraform validate` yet — `ec2.tf` references `aws_ecs_cluster.this` (created in Task 6) and `var.ecs_cluster_name` (added in Task 7), both currently undefined. Validation runs at the end of Task 7 once all files are in place.

- [ ] **Step 4: Commit**

```bash
git add infra/aws/ec2.tf
git commit -m "feat(infra): EC2 launch template, ASG, security group, ECS capacity provider"
```

---

## Task 6: Add `infra/aws/ecs.tf` (cluster + log group + task definition + service)

**Files:**
- Create: `infra/aws/ecs.tf`

- [ ] **Step 1: Create the file**

```hcl
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
```

- [ ] **Step 2: Format only (skip validate)**

```bash
cd infra/aws && terraform fmt ecs.tf && cd ..
```

Do NOT run `terraform validate` yet — `ecs.tf` references `var.ecs_cluster_name` (added in Task 7). Validation runs at the end of Task 7.

- [ ] **Step 3: Commit**

```bash
git add infra/aws/ecs.tf
git commit -m "feat(infra): ECS cluster, task definition, service, log group"
```

---

## Task 7: Rename ECR, restructure variables, update outputs, update VPC refs

**Files:**
- Modify: `infra/aws/ecr.tf`
- Modify: `infra/aws/variables.tf`
- Modify: `infra/aws/outputs.tf`
- Modify: `infra/aws/vpc.tf` (just `var.cluster_name` → `var.ecs_cluster_name`)

- [ ] **Step 1: Rewrite `infra/aws/variables.tf`**

Replace entire file contents with:

```hcl
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
  default     = "code-challenge"
}

variable "ecs_cluster_name" {
  type        = string
  description = "ECS cluster name."
  default     = "code-challenge"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block."
  default     = "10.42.0.0/16"
}
```

- [ ] **Step 2: Rewrite `infra/aws/ecr.tf`**

Replace entire file contents with:

```hcl
resource "aws_ecr_repository" "backend" {
  name                 = "code-challenge-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "code-challenge-backend"
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

- [ ] **Step 3: Rewrite `infra/aws/outputs.tf`**

Replace entire file contents with:

```hcl
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
```

- [ ] **Step 4: Edit `infra/aws/vpc.tf` — replace every `var.cluster_name` with `var.ecs_cluster_name`**

This touches 6 lines (Names of: vpc, igw, public subnet, private subnet, nat eip, nat gw, public route table, private route table). Use a global replace:

```bash
sed -i '' 's/var\.cluster_name/var.ecs_cluster_name/g' infra/aws/vpc.tf
```

Verify:

```bash
grep -n 'cluster_name' infra/aws/vpc.tf
```

Expected: every match should now read `var.ecs_cluster_name` — no bare `var.cluster_name` remaining.

- [ ] **Step 5: Validate the whole module**

```bash
cd infra/aws && terraform fmt && terraform validate
cd ..
```

Expected: `Success! The configuration is valid.` (ECS files added in Tasks 4–6 will now resolve because `var.ecs_cluster_name` exists.)

- [ ] **Step 6: Commit**

```bash
git add infra/aws/
git commit -m "$(cat <<'EOF'
refactor(infra): rename ECR repo, restructure vars, replace EKS outputs

ECR repo sorcery-solutions-backend → code-challenge-backend.
var.cluster_name → var.ecs_cluster_name (default code-challenge).
var.project default → code-challenge.
Delete var.kubernetes_version.
Outputs: replace service_hostname (NLB) with instance_public_ip
(EC2). smoke_test_commands updated for / + SQLi + RCE.
EOF
)"
```

---

## Task 8: Rename `sorcery` → `code-challenge` across remaining files + add Wiz `moved` block

**Files (any file containing the literal `sorcery`):**
- Modify: `app/database.py` (seed email)
- Modify: `infra/wiz/providers.tf` (Project tag)
- Modify: `infra/wiz/wiz-iam/providers.tf` (Project tag)
- Modify: `infra/wiz/connector_aws.tf` (resource address, outputs, **add `moved` block**)
- Modify: `README.md`
- Modify: `GUIDE.md`
- Modify: `docs/superpowers/plans/2026-06-01-sql-injection-demo.md`
- Modify: `docs/superpowers/plans/2026-06-02-eks-deploy.md`
- Modify: `docs/superpowers/specs/2026-06-01-sql-injection-demo-design.md`
- Modify: `docs/superpowers/specs/2026-06-02-eks-deploy-design.md`

- [ ] **Step 1: List every file currently containing `sorcery`**

```bash
grep -ril 'sorcery' . --exclude-dir=.git --exclude-dir=.terraform
```

Expected: the files listed above. Note any unexpected files in the output and stop to investigate. The new spec/plan (`2026-06-04-*`) should also appear because they reference the rename — that's fine, see Step 4.

- [ ] **Step 2: Global rename across all listed files**

Use sed in-place. This handles all naming styles in the codebase (`sorcery`, `sorcery-solutions-backend`, `sorcery-demo`, `sorcery-wiz-connector`, `sorcery-solutions-eks-demo`, etc.) — but the replacement target depends on the prior naming style. We do TWO passes:

1. First, replace the compound names that need specific targets:

```bash
# Strict substring replacement — works for: sorcery-solutions-backend → code-challenge-backend,
# sorcery-demo → code-challenge, sorcery-wiz-connector → code-challenge-wiz-connector,
# sorcery-solutions-eks-demo → code-challenge, sorcery.example → code-challenge.example
# By doing it in this order, we don't accidentally double-replace.

find . -type f \
  ! -path './.git/*' ! -path '*/.terraform/*' \
  -exec grep -l 'sorcery' {} \; \
| while read -r f; do
    # Most specific patterns first
    sed -i '' \
      -e 's|sorcery-solutions-eks-demo|code-challenge|g' \
      -e 's|sorcery-solutions-backend|code-challenge-backend|g' \
      -e 's|sorcery-wiz-connector|code-challenge-wiz-connector|g' \
      -e 's|sorcery-demo|code-challenge|g' \
      -e 's|sorcery_demo|code_challenge_demo|g' \
      -e 's|@sorcery\.example|@code-challenge.example|g' \
      -e 's|aws_sorcery|aws_code_challenge|g' \
      -e 's|sorcery|code-challenge|g' \
      "$f"
  done
```

The last `s|sorcery|code-challenge|g` is a catch-all for any remaining bare `sorcery` (e.g., README prose like "Sorcery Solutions").

2. Verify nothing remains:

```bash
grep -ril 'sorcery' . --exclude-dir=.git --exclude-dir=.terraform
```

Expected: empty.

- [ ] **Step 3: Fix `README.md` title casing**

The sed pass turns "Sorcery Solutions Backend" into "code-challenge Solutions Backend" — clean that up:

```bash
sed -i '' \
  -e 's|^# code-challenge Solutions Backend|# Code Challenge Backend|' \
  README.md
```

Also check if the README has any other "Sorcery Solutions" (with title casing) prose that needs human-readable cleanup. The sed pass only handles lowercase `sorcery`. Search:

```bash
grep -i 'sorcery' README.md GUIDE.md
```

Expected: empty (case-insensitive).

If matches surface, apply manual edits to make the prose read naturally.

- [ ] **Step 4: Add Wiz `moved` block to preserve state**

The sed pass in Step 2 renamed `wiz-v2_generic_connector.aws_sorcery` to `wiz-v2_generic_connector.aws_code_challenge` in `infra/wiz/connector_aws.tf`. Without a `moved` block, Terraform will plan to destroy + create. Append the `moved` block.

Append to the end of `infra/wiz/connector_aws.tf`:

```hcl

# Preserve state across the sorcery → code-challenge rename. Without this,
# `terraform apply` would destroy and recreate the connector, losing scan
# history and re-onboarding the AWS account in Wiz.
moved {
  from = wiz-v2_generic_connector.aws_sorcery
  to   = wiz-v2_generic_connector.aws_code_challenge
}
```

- [ ] **Step 5: Validate both Terraform modules**

```bash
cd infra/aws && terraform fmt && terraform validate && cd ..
cd infra/wiz && terraform fmt && terraform validate && cd ..
```

Expected: both validate cleanly.

- [ ] **Step 6: Plan the Wiz module to confirm `moved` works**

```bash
cd infra/wiz && terraform plan
cd ..
```

Expected output should include a `Terraform will perform the following actions:` section showing:
- `wiz-v2_generic_connector.aws_sorcery has moved to wiz-v2_generic_connector.aws_code_challenge` (no destroy/create)
- An in-place update on the connector's tags (Project tag value change)
- No other changes

If the plan shows destroy + create for the connector, the `moved` block didn't take — stop and debug before applying.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: rename sorcery → code-challenge across repo

App seed email, Wiz Project tag and connector resource address, README,
GUIDE, and historical plans/specs all renamed. Wiz `moved` block
preserves connector state across the resource rename so scan history
is not lost.
EOF
)"
```

---

## Task 9: Apply `infra/aws` — create ECS stack

**Files:** none — state changes only.

- [ ] **Step 1: Verify SSO logged in**

```bash
aws sts get-caller-identity --profile dev-product-cto-play
```

If expired, prompt the user to run `aws sso login --profile dev-product-cto-play`.

- [ ] **Step 2: Run terraform plan**

```bash
cd infra/aws && terraform plan -out=tfplan
```

Expected plan summary:
- **Destroy:** `aws_ecr_repository.backend` (the old `sorcery-solutions-backend` repo)
- **Create:** new `aws_ecr_repository.backend` named `code-challenge-backend`, `aws_ecr_lifecycle_policy.backend` (re-created), `aws_iam_role.ecs_instance`, `aws_iam_role.ecs_task_execution`, attached policies, `aws_iam_instance_profile.ecs_instance`, `aws_security_group.backend`, `aws_launch_template.ecs`, `aws_autoscaling_group.ecs`, `aws_ecs_cluster.this`, `aws_ecs_capacity_provider.this`, `aws_ecs_cluster_capacity_providers.this`, `aws_cloudwatch_log_group.backend`, `aws_ecs_task_definition.backend`, `aws_ecs_service.backend`, `data.aws_instances.backend`, `data.aws_ssm_parameter.ecs_ami`
- **Replace:** `terraform_data.image_build` (because the repository_url it references changes)
- **No-op:** VPC, subnets, IGW, NAT, route tables (just tag updates on subnets after dropping `kubernetes.io/*`)

If the plan tries to destroy the VPC/subnets, stop — something is off. If it tries to create EKS resources, stop — Task 3 didn't fully delete eks.tf.

- [ ] **Step 3: Apply**

```bash
terraform apply tfplan
```

Expected: ~5–8 minutes (ASG instance boot + ECS task placement is the slowest part).

- [ ] **Step 4: Wait for the ECS service to reach RUNNING**

```bash
aws ecs describe-services \
  --cluster code-challenge --services backend \
  --profile dev-product-cto-play --region us-east-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,events:events[0:3].message}' --output json
```

Repeat every ~30s until `running=1, pending=0`. Total wait ~2 minutes from apply completion (ASG must launch instance, instance must register with cluster, service places task).

If `running` stays at 0 for >5 minutes, check:
- `aws ecs list-container-instances --cluster code-challenge --profile dev-product-cto-play --region us-east-1` — should show 1 instance ARN. If empty, the EC2 instance didn't join (check user-data, check IAM instance profile).
- `aws logs tail /ecs/code-challenge-backend --profile dev-product-cto-play --region us-east-1 --since 5m` — container logs. If permission denied for log group access yet, retry in 60s.

- [ ] **Step 5: Refresh outputs**

```bash
make outputs
cd ..
```

Expected: `instance_public_ip` populated with a real IP, `smoke_test_commands` shows real curl commands.

No commit — only state changes.

---

## Task 10: Apply `infra/wiz` — apply tag updates + `moved` block

**Files:** none — state changes only.

- [ ] **Step 1: Plan**

```bash
cd infra/wiz && terraform plan -out=tfplan
```

Expected:
- `wiz-v2_generic_connector.aws_sorcery has moved to wiz-v2_generic_connector.aws_code_challenge`
- In-place update on the connector's tags (Project changes from `sorcery-wiz-connector` to `code-challenge-wiz-connector`)
- 0 to destroy, 0 to create

If anything is destroyed or created, stop and debug.

- [ ] **Step 2: Apply**

```bash
terraform apply tfplan
cd ..
```

Expected: ~30 seconds.

No commit — only state changes.

---

## Task 11: Final smoke tests + verification

**Files:** none.

- [ ] **Step 1: Capture the public IP from outputs**

```bash
cd infra/aws
IP=$(terraform output -raw instance_public_ip)
echo "Instance IP: $IP"
cd ..
```

If `$IP` is `(instance not yet running)`, wait 60s and retry. If still empty, jump back to Task 9 Step 4 troubleshooting.

- [ ] **Step 2: Run the four smoke tests**

```bash
echo "--- sample root ---"
curl -sS "http://$IP:8000/" && echo

echo "--- benign user lookup ---"
curl -sS "http://$IP:8000/api/users?username=alice" && echo

echo "--- SQL injection exploit ---"
curl -sS --get "http://$IP:8000/api/users" --data-urlencode "username=' OR '1'='1" && echo

echo "--- command injection ---"
curl -sS "http://$IP:8000/api/execute?command=id" && echo
```

Expected:
1. `{"name":"code-challenge-backend","message":"sample text"}`
2. `[{"id":1,"username":"alice","email":"alice@example.com","role":"user"}]`
3. `[{"id":1,"username":"alice",...},{"id":2,"username":"bob",...},{"id":3,"username":"admin","email":"admin@code-challenge.example","role":"admin"}]`
4. `{"stdout":"uid=0(root) gid=0(root) groups=0(root)\n","stderr":""}` (or similar uid depending on the container user)

- [ ] **Step 3: Verify AWS-side state**

```bash
# No EKS clusters in this account/region
aws eks list-clusters --profile dev-product-cto-play --region us-east-1
# Should be: { "clusters": [] }

# No ELBs in this account/region with sorcery prefix or the old hash
aws elb describe-load-balancers --profile dev-product-cto-play --region us-east-1 --output table 2>&1 | head -5
aws elbv2 describe-load-balancers --profile dev-product-cto-play --region us-east-1 --query 'LoadBalancers[?contains(LoadBalancerName, `sorcery`) || contains(LoadBalancerName, `a4df`)]' --output json
# Both should be empty

# One ECR repo, the new name
aws ecr describe-repositories --profile dev-product-cto-play --region us-east-1 --query 'repositories[].[repositoryName]' --output text
# Should include code-challenge-backend; should NOT include sorcery-solutions-backend

# ECS cluster + service + running task
aws ecs describe-services --cluster code-challenge --services backend --profile dev-product-cto-play --region us-east-1 --query 'services[0].{name:serviceName,desired:desiredCount,running:runningCount}' --output json
# Should be: { "name": "backend", "desired": 1, "running": 1 }
```

- [ ] **Step 4: Verify no `sorcery` strings remain in the repo**

```bash
grep -ril 'sorcery' . --exclude-dir=.git --exclude-dir=.terraform
```

Expected: empty.

- [ ] **Step 5: Verify Wiz connector state preserved**

```bash
cd infra/wiz
terraform output aws_connector_id
cd ..
```

Expected: same connector ID as before the rename. Cross-check against the Wiz UI — the connector should still appear with its original scan history. If a different ID is returned, the `moved` block didn't take — the connector was destroyed and recreated.

- [ ] **Step 6: Final commit (if any uncommitted changes from validation/formatting)**

```bash
git status
```

If anything is uncommitted (e.g., `terraform fmt` reformatted a file), commit it:

```bash
git add -A
git commit -m "chore: post-apply formatting"
```

Otherwise skip.

---

## Rollback procedure (if Phase 1 destroy succeeds but Phase 2 apply fails)

The destroyed EKS resources can be recreated from git:

```bash
# Roll source back to pre-migration commit
git revert HEAD~N..HEAD  # N = number of commits made during this plan
# OR, if revert is messy:
git reset --hard be3181a   # last known-good commit

# Reapply EKS
cd infra/aws
terraform init -upgrade
terraform apply
```

Note: images previously pushed to the old `sorcery-solutions-backend` ECR are NOT recoverable. The `image.tf` build will push a fresh image on apply.

---

## Open follow-ups (not in scope)

- HTTPS / TLS termination on :8000 (currently raw HTTP).
- ASG instance refresh policy on launch template changes (currently must manually terminate the instance to pick up new AMI versions).
- CloudWatch Logs retention beyond 7 days.
- Multi-AZ HA for the EC2 instance (currently single-AZ, single instance).

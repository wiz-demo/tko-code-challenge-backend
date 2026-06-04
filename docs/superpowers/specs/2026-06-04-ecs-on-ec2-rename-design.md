# Replace EKS with ECS-on-EC2; rename sorcery → code-challenge

**Date:** 2026-06-04
**Supersedes:** `2026-06-02-eks-deploy-design.md`

## Goals

1. Replace the EKS + Helm runtime with a minimal AWS-native container deploy: ECS cluster, one EC2 instance, one task, public on port 8000.
2. Rename every occurrence of `sorcery` to `code-challenge` across code, config, infrastructure resource names, and historical documentation.
3. Trim the app to two intentional-vuln endpoints plus a sample-text root. Drop MongoDB, Bedrock, and YAML-deserialization endpoints.

The result honors "simple EC2, all Terraform": ECS handles container lifecycle (pull/run/restart) declaratively, no hand-written shell beyond the one-line `ECS_CLUSTER=` user-data.

## Non-goals

- HTTPS / TLS / custom domain. Stays HTTP on `:8000` against a raw public IP.
- High availability or autoscaling. ASG desired/min/max = 1, single AZ.
- CI/CD or remote Terraform state. `terraform apply` from a laptop.
- New test suite.
- Renaming or restructuring `infra/wiz/wiz-iam/` beyond the `Project` tag and the connector resource address.
- Touching `docker/wizos/` (only `docker/debian/` is used by `image.tf`).
- Backup, log retention beyond defaults, KMS for ECR, ECR image scanning. None were configured before; not added now.

## Final architecture

```
internet → SG :8000 → EC2 (ECS-optimized AL2023 AMI)
                          ↑ joined to ↓
                      ECS cluster "code-challenge"
                          ↓ runs
                      ECS service (desired=1)
                          ↓ instantiates
                      Task definition
                          ├─ container "backend"
                          │   image: ECR/code-challenge-backend:<git-sha>
                          │   portMappings: [{containerPort: 8000, hostPort: 8000, protocol: tcp}]
                          │   logConfiguration: awslogs → CloudWatch Logs
                          └─ executionRoleArn (ECR pull + log writes)
```

- One EC2 instance in a public subnet with a public IP.
- ECR keeps the image. `image.tf` retains the buildx + push flow, only the repository name changes.
- CloudWatch Logs replaces `kubectl logs`.
- SSM Session Manager replaces SSH; no key pair, no port 22 ingress.
- VPC stays (existing `vpc.tf`), with EKS-only subnet tags removed.

## Terraform resource layout

| File | Change | Resources |
|---|---|---|
| `infra/aws/vpc.tf` | modified | Drop `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` subnet tags. Keep VPC + public/private subnets. |
| `infra/aws/ecr.tf` | modified | Rename `aws_ecr_repository.backend.name` from `sorcery-solutions-backend` to `code-challenge-backend`. Lifecycle policy unchanged. |
| `infra/aws/image.tf` | unchanged logic | `terraform_data.image_build` still does buildx + push. Retags to the new ECR URL automatically via reference. |
| `infra/aws/ecs.tf` | new | `aws_ecs_cluster`, `aws_cloudwatch_log_group`, `aws_ecs_task_definition`, `aws_ecs_service`, `aws_ecs_cluster_capacity_providers`. |
| `infra/aws/ec2.tf` | new | `aws_launch_template`, `aws_autoscaling_group`, `aws_ecs_capacity_provider`, `aws_security_group`. |
| `infra/aws/iam.tf` | new | EC2 instance role, instance profile, ECS task execution role. |
| `infra/aws/outputs.tf` | modified | Replace `service_hostname` with `instance_public_ip` / `instance_public_dns` (via `aws_instances` data source filtered by the ASG name). Update `smoke_test_commands`. |
| `infra/aws/variables.tf` | modified | Rename `var.cluster_name` → `var.ecs_cluster_name` (default `code-challenge`). Update `var.project` default `sorcery-solutions-eks-demo` → `code-challenge`. Delete `var.kubernetes_version`. Keep `region`, `aws_profile`, `owner`, `vpc_cidr` unchanged. |
| `infra/aws/versions.tf` | modified | Drop `hashicorp/helm` and `hashicorp/kubernetes` provider requirements. Keep `hashicorp/aws`, `hashicorp/external`. |
| `infra/aws/eks.tf` | **deleted** | — |
| `infra/aws/k8s.tf` | **deleted** | — |
| `helm/sorcery-solutions-backend/` | **deleted** | Entire directory. |

### Key resource specifics

**`aws_ecs_cluster`**
- `name = "code-challenge"`

**`aws_ecs_task_definition`**
- `family = "code-challenge-backend"`
- `network_mode = "bridge"` (default, container port mapped to host port)
- `requires_compatibilities = ["EC2"]`
- `execution_role_arn` = task execution role (ECR pull + CloudWatch Logs)
- Container spec (JSON):
  - `name = "backend"`
  - `image = "<ecr_url>:<git_sha>"` (sourced from `local.image_uri` in `image.tf`)
  - `portMappings = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]`
  - `essential = true`
  - `logConfiguration` = awslogs driver → `/ecs/code-challenge-backend` log group, `us-east-1`, `ecs` prefix
  - `cpu = 256`, `memory = 512`

**`aws_ecs_service`**
- `name = "backend"`
- `cluster = aws_ecs_cluster.this.id`
- `task_definition = aws_ecs_task_definition.backend.arn`
- `desired_count = 1`
- `launch_type = "EC2"` (or capacity provider strategy referencing `aws_ecs_capacity_provider.this`)
- Depends on `image_build` so the image exists before the service tries to pull.

**`aws_launch_template`**
- `image_id` = SSM parameter lookup: `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id`
- `instance_type = "t3.small"`
- `iam_instance_profile` = the EC2 instance profile (below)
- `vpc_security_group_ids` = the new SG
- `user_data` = base64 of `#!/bin/bash\necho ECS_CLUSTER=code-challenge >> /etc/ecs/ecs.config`
- `tag_specifications` for instances: `owner = <var>`, `extend = "true"`, `Name = "code-challenge-backend"`

**`aws_autoscaling_group`**
- `desired_capacity = 1`, `min_size = 1`, `max_size = 1`
- `vpc_zone_identifier` = first public subnet
- Launch template above
- `tag` propagate `AmazonECSManaged` = true (required for capacity provider)

**`aws_ecs_capacity_provider`** + **`aws_ecs_cluster_capacity_providers`**
- Wraps the ASG; default strategy weight 1, base 1.

**`aws_security_group`**
- ingress: 8000/tcp from `0.0.0.0/0`
- egress: all to `0.0.0.0/0`
- No SSH (port 22) ingress.

**IAM (`iam.tf`)**
- EC2 instance role: managed policies `AmazonEC2ContainerServiceforEC2Role` (ECS agent registration + ECR read) and `AmazonSSMManagedInstanceCore` (Session Manager).
- EC2 instance profile wrapping the above.
- ECS task execution role: managed policy `AmazonECSTaskExecutionRolePolicy` (ECR pull + CloudWatch Logs write).
- No task role (the app makes no AWS API calls after Bedrock removal).

All resources tagged `owner = <var>`, `extend = "true"` per the project's tagging policy (CLAUDE.md).

## App changes

### `app/main.py`

| Endpoint | Action |
|---|---|
| `GET /` | **add** — returns `{"name": "code-challenge-backend", "message": "sample text"}` |
| `GET /api/users?username=` | **keep** — SQL injection (CWE-89) via string-formatted query on in-memory SQLite |
| `GET /api/execute?command=` | **keep** — command injection via `subprocess.Popen(..., shell=True)` |
| `POST /api/prompts` | **delete** |
| `GET /api/prompts` | **delete** |
| `POST /api/import_prompts` | **delete** |
| `POST /api/chat` | **delete** |

Also drop these imports/blocks: `import yaml`, `import boto3`, `from botocore.exceptions import ClientError`, `from schemas import Prompt, YAMLPrompts, ChatMessage`, `from models import prompt_helper`, Bedrock client init, `BEDROCK_REGION` / `BEDROCK_AGENT_ID` / `BEDROCK_AGENT_ALIAS_ID` env reads. CORS middleware stays. `logging` stays (used by remaining endpoints if needed).

### `app/database.py`

- Delete: `motor.motor_asyncio` import, `load_dotenv`, `MONGO_URI`, `MONGO_DB`, `client`, `db`.
- Keep: the in-memory SQLite block, seeded with 3 rows.
- Rename seed: `admin@sorcery.example` → `admin@code-challenge.example`.

### `app/schemas.py`

- Delete `Prompt`, `YAMLPrompts`, `ChatMessage` classes. If the file becomes empty, delete the file and remove its import from `main.py`.

### `app/models.py`

- Delete `prompt_helper`. If the file becomes empty, delete the file.

### `app/requirements.txt`

- Drop: `motor`, `pyyaml`, `boto3`, `python-dotenv`.
- Keep: `fastapi`, `uvicorn`.
- Audit during implementation for transitive entries that should also be removed (e.g., `pymongo`, pinned via `motor`).

### `docker/debian/Dockerfile`

No functional change. The smaller `requirements.txt` just builds faster. Verify the entrypoint still works (`uvicorn main:app --host 0.0.0.0 --port 8000`).

### Behavioral side effects (intentional)

- `import yaml`, `import boto3`, etc. are removed. The Wiz SCA "vulnerable dependency" demo around the pinned PyYAML version goes away. User opted to drop these for simplicity.
- Mongo connectivity error path is gone — no more `motor` connection attempts at startup.

## Rename: sorcery → code-challenge

### Strict rule

Every textual occurrence of `sorcery` becomes `code-challenge`. Applies to: live code, infrastructure, configuration, READMEs, GUIDE, **and historical docs under `docs/superpowers/plans/` and `docs/superpowers/specs/`**. User explicitly chose to rewrite the historical docs as well.

### Resource-level renames

| Old | New |
|---|---|
| `helm/sorcery-solutions-backend/` (dir) | deleted entirely |
| ECR repo `sorcery-solutions-backend` | `code-challenge-backend` |
| EKS cluster `sorcery-demo` | n/a — cluster destroyed |
| `var.project` default `sorcery-solutions-eks-demo` | `code-challenge` |
| `var.cluster_name` (renamed to `var.ecs_cluster_name`) default `sorcery-demo` | `code-challenge` |
| Tag `Project = "sorcery-wiz-connector"` (infra/wiz) | `Project = "code-challenge-wiz-connector"` |
| Terraform resource `wiz-v2_generic_connector.aws_sorcery` | `wiz-v2_generic_connector.aws_code_challenge` |
| `app/database.py` seed `admin@sorcery.example` | `admin@code-challenge.example` |
| `README.md` title "Sorcery Solutions Backend" | "Code Challenge Backend" |
| All other prose `sorcery*` references | `code-challenge*` |

### Wiz state continuity — `moved` block

To preserve the existing Wiz connector and its scan history despite the Terraform resource address rename, add to `infra/wiz/`:

```hcl
moved {
  from = wiz-v2_generic_connector.aws_sorcery
  to   = wiz-v2_generic_connector.aws_code_challenge
}
```

The connector's `id` (state) is preserved; only the address changes. The `Project` tag change is an in-place update on the existing resource.

### ECR repo rename — destroy + create

`aws_ecr_repository.backend` keeps its Terraform address; only the `name` attribute changes. Terraform will destroy the old `sorcery-solutions-backend` repo and create `code-challenge-backend`. This drops any images currently in the old repo. Acceptable: `image.tf` rebuilds and pushes on every apply.

## Migration / apply order

Single apply won't work cleanly because removing the helm/kubernetes providers in the same plan that destroys the helm release causes plan-time provider errors.

### Phase 1 — Tear down EKS (providers still defined)

From `infra/aws/`:

1. `terraform destroy -target=helm_release.backend -target=data.kubernetes_service.backend` — releases the ELB, removes the helm release while the kubernetes/helm providers still exist.
2. Destroy EKS cluster and dependencies:
   ```
   terraform destroy \
     -target=aws_eks_access_policy_association.admin \
     -target=aws_eks_access_entry.admin \
     -target=aws_eks_node_group.general \
     -target=aws_eks_cluster.this \
     -target=aws_iam_role_policy_attachment.node \
     -target=aws_iam_role_policy_attachment.cluster \
     -target=aws_iam_role.node \
     -target=aws_iam_role.cluster
   ```
3. Verify in AWS console: no ELBs in `us-east-1`, no EKS cluster `sorcery-demo`. (Old ECR repo deletion happens in Phase 2.)

### Phase 2 — Restructure code, then apply

4. Delete `infra/aws/eks.tf`, `infra/aws/k8s.tf`, `helm/sorcery-solutions-backend/`.
5. Drop `hashicorp/helm` and `hashicorp/kubernetes` from `infra/aws/versions.tf`.
6. Add `infra/aws/ecs.tf`, `infra/aws/ec2.tf`, `infra/aws/iam.tf`.
7. Modify `ecr.tf` (rename), `variables.tf` (defaults), `outputs.tf` (new outputs), `vpc.tf` (drop subnet tags).
8. Rename `sorcery` → `code-challenge` across all remaining files (app, README, GUIDE, historical docs, wiz tfvars).
9. Add `moved` block in `infra/wiz/`.
10. `cd infra/aws && terraform init -upgrade && terraform apply` — expected plan: destroy old ECR, create new ECR, image rebuild + push, ECS cluster, EC2 launch template + ASG, capacity provider, ECS task, ECS service, IAM roles, log group, SG.
11. `cd infra/wiz && terraform apply` — expected plan: in-place tag update on the connector (project tag), `moved` block applied (no destroy), zero infra churn.

### Verification

After Phase 2, against `terraform output instance_public_dns`:

- `curl http://<dns>:8000/` → `{"name": "code-challenge-backend", "message": "sample text"}`
- `curl "http://<dns>:8000/api/users?username=alice"` → one row (`alice`)
- `curl --get "http://<dns>:8000/api/users" --data-urlencode "username=' OR '1'='1"` → three rows (SQLi works)
- `curl "http://<dns>:8000/api/execute?command=id"` → uid/gid output (RCE works)
- AWS console:
  - 1 ECS cluster `code-challenge`, 1 service `backend`, 1 RUNNING task
  - 1 EC2 instance (ASG `code-challenge-*`), tag `owner=...`, `extend=true`
  - 0 EKS clusters, 0 ELBs (in `us-east-1` for this project)
  - 1 ECR repo `code-challenge-backend` with one image tagged `<git-sha>`
  - CloudWatch log group `/ecs/code-challenge-backend` with container stdout

### Rollback

Phase 1 is destructive — once EKS is gone, restoring it means `git revert` to commit `be3181a` and re-applying. Image data in the old ECR repo is not recoverable. This is acceptable for a lab.

## Risks / open items

- **ECS-optimized AL2023 AMI ID lookup:** uses the SSM parameter `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id` (AWS's documented public parameter for the recommended ECS-optimized AL2023 image; region-aware via the provider's region). Implementer should `aws ssm get-parameter --name <path> --region us-east-1` once during the plan task to confirm the parameter resolves before wiring it into the launch template.
- **Capacity provider chicken-and-egg:** the ECS service depends on the capacity provider, which depends on the ASG, which depends on the launch template, which depends on the instance profile. Terraform should resolve this through implicit references; explicit `depends_on` only if apply errors surface.
- **First-apply task startup:** the EC2 instance needs ~60s to boot and register with ECS before the service can place the task. `aws_ecs_service` may report `desired_count=1, running_count=0` during the first apply; this is normal. Smoke tests need to wait for the task to be `RUNNING`.
- **EC2 instance replacement loses the running container:** ASG instance refresh / failure → new instance → fresh task. Brief downtime (~3 min). Acceptable for a lab.

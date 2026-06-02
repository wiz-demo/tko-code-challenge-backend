# EKS Deployment for sorcery-solutions-backend

**Date:** 2026-06-02
**Status:** Approved
**Target environment:** AWS account `800618367342` (`dev-product-cto-play` SSO profile, per project `CLAUDE.md`)

## Goal

Deploy the FastAPI demo backend — including the intentional CWE-78 / CWE-89 /
CWE-502 vulnerabilities — to a fresh EKS Auto Mode cluster in `us-east-1`, via
Terraform. End state: a publicly reachable Network Load Balancer URL that
serves the app, with the SQL-injection demo endpoint (`/api/users`) live and
exploitable.

The operator runs `terraform apply` locally; that single command provisions
the VPC, the cluster, the ECR repo, builds and pushes the container image,
and installs the existing Helm chart.

## Non-goals

- HTTPS, custom domain, ACM, or Route 53.
- Remote Terraform state. Local state is fine for one operator and easy
  teardown.
- Backing services for MongoDB or Bedrock. `/api/prompts` will time out and
  `/api/chat` will return the existing 500 message. Documented as expected.
- CI integration. The image build runs on the operator's machine.
- Multiple environments. There is one ad-hoc demo cluster.
- Pod security context hardening, network policies, or any defensive
  posture. This is a CTF target — being exploitable is the point.

## High-level architecture

```
        AWS Account 800618367342 (us-east-1)
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  ┌────────────┐                                          │
│  │  ECR Repo  │◄──── docker push (local-exec)            │
│  └─────┬──────┘                                          │
│        │ image pull                                      │
│        ▼                                                 │
│  ┌──────────────────────────────────────────────────┐    │
│  │   VPC 10.42.0.0/16                               │    │
│  │   ┌─────────────┐  ┌─────────────┐               │    │
│  │   │ public 1a   │  │ public 1b   │ ← NLB         │    │
│  │   └─────────────┘  └─────────────┘               │    │
│  │   ┌─────────────┐  ┌─────────────┐               │    │
│  │   │ private 1a  │  │ private 1b  │ ← Auto Mode   │    │
│  │   └─────────────┘  └─────────────┘   pods        │    │
│  │                                                  │    │
│  │   ┌──────────────────────────────────────────┐   │    │
│  │   │  EKS Auto Mode cluster (k8s 1.32)        │   │    │
│  │   │  ┌────────────────────────────────────┐  │   │    │
│  │   │  │ Deployment: sorcery-solutions-...  │  │   │    │
│  │   │  │ ┌──────────────────┐               │  │   │    │
│  │   │  │ │ Pod (port 8000)  │               │  │   │    │
│  │   │  │ └──────────────────┘               │  │   │    │
│  │   │  └────────────────────────────────────┘  │   │    │
│  │   │  ┌────────────────────────────────────┐  │   │    │
│  │   │  │ Service type=LoadBalancer          │  │   │    │
│  │   │  │ → NLB (internet-facing)            │  │   │    │
│  │   │  └────────────────────────────────────┘  │   │    │
│  │   └──────────────────────────────────────────┘   │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
└──────────────────────────────────────────────────────────┘
                          │
                  http://<nlb-dns>:80
                          │
                         User
```

## Repository layout

New directory at repo root:

```
infra/aws/
├── main.tf        # AWS provider + default_tags
├── versions.tf    # required_providers, version pins
├── variables.tf   # owner, region (with defaults)
├── vpc.tf         # VPC, 2 public + 2 private subnets, IGW, single NAT
├── eks.tf         # EKS Auto Mode cluster + caller access entry
├── ecr.tf         # ECR repository
├── image.tf       # null_resource: docker login/build/push
├── k8s.tf         # helm_release of helm/sorcery-solutions-backend
├── outputs.tf     # cluster name, ECR URL, kubeconfig cmd, NLB hostname
└── Makefile       # init, plan, apply, destroy, kubeconfig, smoke
```

Branch: new `feat/eks-deploy`, cut from `feat/sql-injection-demo` so the
deployed image includes the SQL-injection demo endpoint added by that branch.

## Components

### 1. Providers & tags (`main.tf`, `versions.tf`)

- AWS provider `~> 5.70`, region `us-east-1`, profile `dev-product-cto-play`.
- `default_tags`:
  - `owner = "itay.katz"`
  - `project = "sorcery-solutions-eks-demo"`
- No `extend` tag — accept the 30-day auto-cleanup as the safety net.
- helm `~> 2.15`, kubernetes `~> 2.32`, null `~> 3.2`.
- Terraform `>= 1.6`.
- State backend: local (`terraform.tfstate` in the working directory). No
  remote backend. This is acceptable because there is one operator, the
  cluster is throwaway, and a lost state file means `terraform destroy`
  can't be used — at which point the 30-day SCP cleanup catches up.

### 2. Networking (`vpc.tf`)

| Resource | CIDR / detail |
|---|---|
| VPC | `10.42.0.0/16` |
| Public subnet 1 | `10.42.0.0/20` in `us-east-1a`, tag `kubernetes.io/role/elb=1` |
| Public subnet 2 | `10.42.16.0/20` in `us-east-1b`, tag `kubernetes.io/role/elb=1` |
| Private subnet 1 | `10.42.32.0/20` in `us-east-1a`, tag `kubernetes.io/role/internal-elb=1` |
| Private subnet 2 | `10.42.48.0/20` in `us-east-1b`, tag `kubernetes.io/role/internal-elb=1` |
| IGW | one, attached to VPC |
| NAT gateway | one, in public subnet 1 (cost-saving — single AZ NAT) |
| Route tables | one public (→ IGW), one private (→ NAT) shared by both private subnets |

### 3. EKS cluster (`eks.tf`)

- Resource: `aws_eks_cluster` with:
  - `version = "1.32"`
  - `compute_config { enabled = true, node_pools = ["general-purpose"] }`
  - `kubernetes_network_config { elastic_load_balancing { enabled = true } }`
  - `storage_config { block_storage { enabled = true } }`
  - `access_config { authentication_mode = "API" }`
  - `vpc_config`: public + private subnets, public endpoint enabled,
    private endpoint enabled (so terraform's k8s/helm providers reach the API
    server via the public endpoint).
- Cluster IAM role: minimal — `AmazonEKSClusterPolicy`,
  `AmazonEKSComputePolicy`, `AmazonEKSBlockStoragePolicy`,
  `AmazonEKSLoadBalancingPolicy`, `AmazonEKSNetworkingPolicy` (the Auto Mode
  set).
- Node IAM role: minimal — `AmazonEKSWorkerNodeMinimalPolicy`,
  `AmazonEC2ContainerRegistryPullOnly`. No additional permissions — the
  pod's blast radius if compromised stays bounded.
- Access entry: the calling principal (whoever ran `terraform apply`) gets
  the `AmazonEKSClusterAdminPolicy` scope. Resolved via
  `data.aws_caller_identity` → mapped to the `AssumedRole` form expected by
  EKS access entries.

### 4. Container registry (`ecr.tf`)

- `aws_ecr_repository` `sorcery-solutions-backend`:
  - `image_scanning_configuration.scan_on_push = true` (lets Wiz scan).
  - `image_tag_mutability = "MUTABLE"` (so re-builds with the same tag work
    during iteration).
- `aws_ecr_lifecycle_policy`: retain 5 most recent images, expire older.
- `force_delete = true` so `terraform destroy` doesn't error on
  remaining images.

### 5. Image build (`image.tf`)

- `null_resource` with `triggers = { dockerfile_sha = filesha256(...),
  app_sha = sha256(join(... fileset("../../app/**"))) }` so any change to
  the app or the Dockerfile re-builds.
- `provisioner "local-exec"`:
  ```bash
  aws ecr get-login-password --region us-east-1 --profile dev-product-cto-play \
    | docker login --username AWS --password-stdin <ECR registry>
  docker buildx build \
    --platform linux/amd64 \
    -f ../../docker/debian/Dockerfile \
    -t <ECR repo>:<git SHA> \
    --push \
    ../..
  ```
- Image tag: short git SHA of the worktree's HEAD (`substr(data.external.git_sha.result.sha, 0, 7)`).
- `--platform linux/amd64` is mandatory because EKS Auto Mode nodes are
  amd64. Apple-Silicon operators need `docker buildx` (already installed by
  Docker Desktop).

### 6. Kubernetes deployment (`k8s.tf`)

- `helm_release` of `../../helm/sorcery-solutions-backend`, release name
  `sorcery-solutions-backend`, namespace `default`.
- Value overrides (passed via `set` blocks or a generated values fragment):
  ```yaml
  image.repository:             <ECR repository URL>
  image.tag:                    <git SHA from image.tf>
  service.type:                 LoadBalancer
  env.MONGO_URI:                "mongodb://placeholder:27017"
  env.MONGO_DB:                 "sorcery_demo"
  livenessProbe.httpGet.path:   /openapi.json
  livenessProbe.httpGet.port:   http
  readinessProbe.httpGet.path:  /openapi.json
  readinessProbe.httpGet.port:  http
  resources.requests.cpu:       250m
  resources.requests.memory:    256Mi
  resources.limits.cpu:         500m
  resources.limits.memory:      512Mi
  ```
- Depends on the cluster being reachable. The helm provider is configured
  via the cluster output and a token from `data.aws_eks_cluster_auth`.
- `wait = true`, `timeout = 600` so apply blocks until the pod is healthy.

### 7. Outputs (`outputs.tf`)

- `cluster_name`
- `cluster_region`
- `ecr_repository_url`
- `kubeconfig_command` — exact `aws eks update-kubeconfig ...` string with
  the cluster name, region, and profile filled in.
- `service_hostname` — read from the LoadBalancer ingress; may be empty on
  the first apply (NLB takes ~90 s to provision); a `terraform refresh`
  resolves it.
- `smoke_test_commands` — the three curl commands from the verification
  section, with the hostname interpolated. Empty until `service_hostname`
  resolves.

### 8. Makefile

Convenience wrappers:

| target | does |
|---|---|
| `make init` | `terraform -chdir=infra/aws init` |
| `make plan` | `terraform -chdir=infra/aws plan` |
| `make apply` | `terraform -chdir=infra/aws apply` (interactive confirm) |
| `make destroy` | `terraform -chdir=infra/aws destroy` |
| `make kubeconfig` | runs the `kubeconfig_command` output |
| `make smoke` | runs the curls against `service_hostname` |

## Verification

After `terraform apply`:

```bash
make kubeconfig
kubectl get pods                          # backend pod Running
kubectl get svc -o wide                   # NLB hostname populated
make smoke                                # runs three curls
```

Expected:
- `GET /api/users?username=alice` → alice's row
- `GET /api/users?username=' OR '1'='1` → all 3 rows
- `GET /openapi.json` → 200 with the route table

## Accepted risks

1. **The deployed service is intentionally vulnerable.** Anyone on the
   internet who finds the NLB can pop the pod via `/api/execute` (RCE),
   `/api/users` (SQLi), or `/api/import_prompts` (yaml RCE).
2. **Blast radius if popped**: the pod's ServiceAccount has no IAM (no
   IRSA), so AWS-API privilege escalation is bounded by the EKS node IAM
   role (pull-only on ECR + the minimal worker permissions). An attacker
   still gets shell inside the pod and the cluster API via the SA token.
3. **Cost while running** ≈ $5–8/day: $0.10/hr cluster fee + Auto Mode
   compute (~1 vCPU + 1 GiB) + NLB ($0.022/hr) + NAT ($0.045/hr) + minor
   egress. SCP 30-day cleanup is the safety net.
4. **Apply takes ~15–20 min** end-to-end (EKS control plane is the long
   pole).
5. **Local Docker required** with buildx available for `--platform
   linux/amd64`. Will fail loudly otherwise.

## Out-of-scope items the operator may want later

- HTTPS via ALB + ACM + Route53
- Multi-environment separation (staging / prod)
- Remote Terraform state backend (S3 + DynamoDB lock)
- CI integration — image build/push from GitHub Actions instead of local
- Bedrock IAM for `/api/chat`
- DocumentDB or MongoDB Atlas for `/api/prompts`
- Pod security context hardening / network policies / OPA / Kyverno
- Observability stack (Container Insights, Prometheus, etc.)
- GitOps (Argo CD / Flux)

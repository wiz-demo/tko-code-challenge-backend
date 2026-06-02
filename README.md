# Sorcery Solutions Backend

> **This repo is a security demo / CTF target. All secrets are fake. Several
> endpoints contain INTENTIONAL vulnerabilities. Do NOT deploy this code into
> any environment you care about.**

A FastAPI backend that intentionally exposes textbook web vulnerabilities so
SAST tooling (Wiz, Bandit, Semgrep) has something concrete to find and red-team
agents have something concrete to exploit.

## Stack

- Python 3.12 + FastAPI + uvicorn
- MongoDB via `motor` (async client) — used by the prompt CRUD endpoints
- AWS Bedrock Agent (optional) for the chat endpoint
- In-process sqlite (stdlib) for the `/api/users` demo endpoint

## Intentional vulnerabilities

| Endpoint | CWE | Class | What happens |
|---|---|---|---|
| `GET /api/users?username=...` | **CWE-89** | SQL injection | `username` is interpolated into a raw SQL string passed to `sqlite3.Connection.execute`. Payload `' OR '1'='1` returns every user; UNION queries leak the schema. |
| `GET /api/execute?command=...` | **CWE-78** | OS command injection | `command` is passed to `subprocess.Popen(..., shell=True)`. Full shell access as the container's user (root in the deployed image). |
| `POST /api/import_prompts` | **CWE-502** | Insecure deserialization | YAML body is parsed with `yaml.load(..., Loader=yaml.Loader)`. Payloads using `!!python/object/apply:os.system [...]` execute arbitrary code during deserialization, before any application-level validation runs. |

The pinned `PyYAML==5.3` in `app/requirements.txt` is also a known-vulnerable
version flagged by SCA tools.

The wildcard CORS on `app/main.py` (`allow_origins=["*"]` with
`allow_credentials=True`) is also intentional.

## Endpoint reference

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/prompts` | List all prompt templates. Requires Mongo. |
| `POST` | `/api/prompts` | Save a prompt template. Requires Mongo. |
| `GET` | `/api/users?username=...` | **Vulnerable** SQL lookup (sqlite). |
| `GET` | `/api/execute?command=...` | **Vulnerable** shell execution. |
| `POST` | `/api/import_prompts` | **Vulnerable** YAML import. Requires Mongo to actually persist. |
| `POST` | `/api/chat` | Bedrock Agent proxy. Requires `BEDROCK_AGENT_ID` + `BEDROCK_AGENT_ALIAS_ID`. |

## Configuration

| Env var | Required | Description |
|---|---|---|
| `MONGO_URI` | yes | Full URI (including basic auth) for the MongoDB instance. |
| `MONGO_DB` | yes | Database name within the MongoDB instance. |
| `BEDROCK_AGENT_ID` | optional | Agent ID for `/api/chat`. Endpoint returns 500 without it. |
| `BEDROCK_AGENT_ALIAS_ID` | optional | Agent alias ID for `/api/chat`. Endpoint returns 500 without it. |
| `AWS_REGION` | optional | Defaults to `us-east-2` for Bedrock. |

## Running locally

```bash
# Mongo URI can be a placeholder — motor connects lazily, so endpoints
# that don't touch Mongo work without a running database.
MONGO_URI=mongodb://localhost:27017 MONGO_DB=sorcery_demo PYTHONPATH=app \
  python3 -m uvicorn main:app --host 127.0.0.1 --port 8000
```

Then:

```bash
# Benign
curl 'http://127.0.0.1:8000/api/users?username=alice'

# Exploit
curl --get 'http://127.0.0.1:8000/api/users' --data-urlencode "username=' OR '1'='1"
```

## Container image

Two Dockerfiles ship in this repo:

- `docker/debian/Dockerfile` — `python:3.12.1-bullseye` base
- `docker/wizos/Dockerfile` — Wiz OS base (`registry.os.wiz.io/python:3.12`)

Both run `fastapi run main.py --port 8000` and expect to be built from the repo
root:

```bash
docker buildx build --platform linux/amd64 \
  -f docker/debian/Dockerfile -t sorcery-backend:dev .
```

## EKS deployment (Terraform)

`infra/terraform/` provisions a complete EKS environment in AWS, including
VPC + subnets + NAT, ECR repo, EKS cluster (classic mode + managed node group),
and a helm release of `helm/sorcery-solutions-backend/`. State is local.

**Prerequisites on the operator's machine:**

- AWS CLI v2 with an SSO profile that maps to the target account
- Docker Desktop (provides `docker buildx` for `--platform linux/amd64`)
- Terraform `>= 1.6`
- `kubectl` (for post-apply verification)

**Defaults** (overridable in `infra/terraform/variables.tf`):

- Region: `us-east-1`
- AWS profile: `dev-product-cto-play` (must point at account `800618367342`)
- Cluster name: `sorcery-demo`
- Kubernetes version: `1.32`
- Node group: 1× `t3.large` (chosen to satisfy the playground SCP that
  restricts EC2 to `t2/t3/t4g/c5/m5` `large`/`xlarge`)
- `owner` tag: `itay.katz`

**Two-stage apply** (the kubernetes data source in `outputs.tf` can't resolve
before the cluster exists):

```bash
aws sso login --profile dev-product-cto-play

cd infra/terraform
terraform init
terraform apply \
  -target=aws_eks_cluster.this \
  -target=aws_eks_access_policy_association.admin \
  -target=terraform_data.image_build
terraform apply        # full apply once cluster exists
```

Cluster creation alone takes ~10–15 min. Total wall time including node group
and helm install is roughly 18–25 min.

**Operator commands** (`make help` in `infra/terraform/` lists them):

```bash
make kubeconfig        # writes the cluster context into ~/.kube/config
make outputs           # prints terraform outputs including the service hostname
make smoke             # runs the demo curls against the live ELB
make destroy           # tears everything down (≈10 min)
```

**Cost while running**: ~$5–8/day (control plane + node + ELB + NAT). Tag
`extend=true` is NOT set, so the playground's SCP will auto-delete the
resources 30 days after creation.

**Exposure**: the helm release sets `service.type=LoadBalancer` and
`service.port=8000`, which provisions a public Classic ELB listening on **port
8000**. Anyone on the internet who finds the URL can exploit the endpoints
listed in the vulnerabilities table above. Tear it down with `make destroy`
when you're not actively demoing.

## Repository layout

```
app/                         FastAPI app
  main.py                    All endpoints (including the vulnerable ones)
  database.py                Mongo client + in-memory sqlite for /api/users
  schemas.py                 Pydantic models
  models.py                  Mongo document helpers
  requirements.txt
docker/
  debian/Dockerfile          Standard Python image
  wizos/Dockerfile           Wiz OS image (private registry)
helm/sorcery-solutions-backend/  Helm chart for k8s deploy
infra/terraform/             EKS deployment IaC (see "EKS deployment" above)
docs/superpowers/
  specs/                     Design specs for the demo features
  plans/                     Implementation plans for executing the specs
.github/workflows/
  build-scan-push.yml        Image build + Wiz container scan + push pipeline
```

## Tearing down the deployed cluster

```bash
cd infra/terraform
make destroy
```

The destroy step force-deletes the ECR repo even if images remain (the
repository has `force_delete = true`) and removes the local state. If `make
destroy` fails part-way (e.g., the ELB hasn't fully released its ENIs yet),
re-run it after ~5 minutes.

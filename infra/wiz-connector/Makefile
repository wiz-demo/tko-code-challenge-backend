SHELL  := /bin/bash
TF     := terraform
TFVARS := $(CURDIR)/terraform.tfvars

.PHONY: help init plan apply destroy \
        init-iam plan-iam apply-iam destroy-iam \
        init-root plan-root apply-root destroy-root

help:
	@echo "Two-stage workflow (IAM role first, then connector that consumes it):"
	@echo "  init        - terraform init for both sub-projects"
	@echo "  plan        - terraform plan for both sub-projects"
	@echo "  apply       - terraform apply IAM first, then root (connector)"
	@echo "  destroy     - terraform destroy root (connector) first, then IAM"
	@echo
	@echo "Individual targets exist for each stage (init-iam, plan-iam, apply-iam, etc.)."
	@echo
	@echo "REQUIREMENTS before any apply:"
	@echo "  1. Copy terraform.tfvars.example to terraform.tfvars"
	@echo "  2. Fill in wiz_client_id and wiz_client_secret from Wiz Console"
	@echo "     (Settings > Service Accounts)"
	@echo "  3. aws sso login --profile dev-product-cto-play"
	@echo "  4. terraform login tf.app.wiz.io  (only first time, if private registry asks)"

init: init-iam init-root

plan: plan-iam plan-root

apply: apply-iam apply-root

# Reverse order: connector depends on the IAM role, so destroy it first.
destroy: destroy-root destroy-iam

# ---------- wiz-iam sub-project ----------

init-iam:
	cd wiz-iam && $(TF) init

plan-iam:
	cd wiz-iam && $(TF) plan -var-file=$(TFVARS) -compact-warnings

apply-iam:
	cd wiz-iam && $(TF) apply -var-file=$(TFVARS) -auto-approve -compact-warnings

destroy-iam:
	cd wiz-iam && $(TF) destroy -var-file=$(TFVARS) -auto-approve -compact-warnings

# ---------- root (connector) ----------

init-root:
	$(TF) init

plan-root:
	$(TF) plan -var-file=$(TFVARS)

apply-root:
	$(TF) apply -var-file=$(TFVARS) -auto-approve

destroy-root:
	$(TF) destroy -var-file=$(TFVARS) -auto-approve

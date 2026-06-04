SHELL := /bin/bash
TF    := terraform

.PHONY: help init fmt validate plan apply destroy outputs smoke

help:
	@echo "Targets:"
	@echo "  init        - terraform init"
	@echo "  fmt         - terraform fmt"
	@echo "  validate    - terraform validate"
	@echo "  plan        - terraform plan (requires SSO: aws sso login --profile cto-experts)"
	@echo "  apply       - terraform apply (requires SSO)"
	@echo "  destroy     - terraform destroy (requires SSO)"
	@echo "  outputs     - refresh state and print outputs"
	@echo "  smoke       - hit the deployed endpoint with benign + exploit payloads"

init:
	$(TF) init -input=false

fmt:
	$(TF) fmt

validate:
	$(TF) validate

plan:
	$(TF) plan

apply:
	$(TF) apply

destroy:
	$(TF) destroy

outputs:
	@$(TF) refresh > /dev/null
	@$(TF) output

smoke:
	@$(TF) refresh > /dev/null
	@eval "$$($(TF) output -raw smoke_test_commands)"

github_org  = "kombaraj-ai"
github_repo = "uc02-mf-strands-agents-phase-03"

# Numeric IDs GitHub's OIDC tokens actually embed in the "sub" claim for
# this repo (real trust-policy failure was diagnosed via a live CloudTrail
# AssumeRoleWithWebIdentity event, 2026-08-08 - see variables.tf's comment).
# Re-verify these (GitHub API: GET /orgs/kombaraj-ai and
# GET /repos/kombaraj-ai/uc02-mf-strands-agents-phase-03, both return an
# "id" field) if this repo is ever renamed or transferred again.
github_org_id  = "216298138"
github_repo_id = "1299897329"

# From: terraform -chdir=infra/terraform/bootstrap output state_bucket_name
state_bucket_name = "amc-orchestrator-tfstate-766354255780"

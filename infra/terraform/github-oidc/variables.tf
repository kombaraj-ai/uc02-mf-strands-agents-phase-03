variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "amc-orchestrator"
}

variable "github_org" {
  description = "GitHub organization or user that owns the repository, e.g. \"my-org\" in \"my-org/amc-orchestrator\". Scopes the OIDC trust policies' `sub` claim condition - see oidc_provider.tf/plan_role.tf/deploy_role.tf."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name only, without the org, e.g. \"amc-orchestrator\"."
  type        = string
}

# GitHub's OIDC `sub` claim is NOT always the plain "repo:OWNER/REPO:..."
# format the AWS provider's own docs show as the example - confirmed via a
# real failed AssumeRoleWithWebIdentity call, diagnosed through CloudTrail
# (StringEquals trust conditions give no useful error otherwise): once this
# repo was renamed, GitHub started emitting
# "repo:OWNER@OWNER_ID/REPO@REPO_ID:..." instead - appending each entity's
# stable numeric ID after an "@". Believed to be GitHub's guard against a
# renamed repo's old name being reclaimed by a different, untrusted repo
# later. The trust policies in plan_role.tf/deploy_role.tf must match
# whatever GitHub is *actually* sending, not the plain form - get these two
# IDs from a real STS CloudTrail event (or the GitHub API's
# `GET /orgs/{org}` / `GET /repos/{owner}/{repo}` `id` fields) rather than
# guessing, and re-verify after any future rename.
variable "github_org_id" {
  description = "GitHub organization's numeric ID (immutable across renames) - see the comment above for why this is needed in the OIDC sub claim."
  type        = string
}

variable "github_repo_id" {
  description = "GitHub repository's numeric ID (immutable across renames) - see the comment above for why this is needed in the OIDC sub claim."
  type        = string
}

variable "state_bucket_name" {
  description = "The Terraform state bucket infra/terraform/bootstrap already created (terraform -chdir=infra/terraform/bootstrap output state_bucket_name). Each deploy role gets read/write access scoped to its own environment's object-key prefix in this bucket."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

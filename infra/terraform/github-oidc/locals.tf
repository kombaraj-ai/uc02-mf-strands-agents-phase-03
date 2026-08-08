data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # See variables.tf's github_org_id/github_repo_id comment - this is the
  # actual "sub" prefix GitHub's OIDC tokens carry for this repo, confirmed
  # against real CloudTrail AssumeRoleWithWebIdentity events, not the plain
  # "repo:OWNER/REPO" form the AWS provider's example docs show.
  github_sub_prefix = "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"

  common_tags = merge(var.tags, {
    Project   = var.project
    ManagedBy = "terraform"
    Component = "github-oidc"
  })
}

# --- plan_role ---------------------------------------------------------
# Assumed only by pr-validate.yml's tf-plan job, which runs automatically on
# every pull_request - including from this repo's own less-trusted,
# runs-on-every-push context. Read-only by design: AWS managed
# ReadOnlyAccess rather than a hand-rolled read policy, deliberately -
# `terraform plan` needs read access to essentially every resource type this
# project's modules touch, and an incomplete custom read policy would
# silently break `plan` on whatever action got missed (this project has hit
# that exact class of bug before with hand-enumerated IAM actions - see
# modules/iam/knowledge_base_role.tf's S3VectorsDataPlane comment).
# ReadOnlyAccess grants zero mutating actions, so the "a PR can never apply
# anything" safety property holds regardless of how complete the policy is.
#
# Shared across all three environments rather than one role per environment,
# because it's read-only - the blast radius of over-broad read access is
# low, and three near-identical roles would add real maintenance cost for
# no meaningful safety gain on a project this size.
#
# Trust condition matches `sub = "...:pull_request"` exactly (StringEquals,
# not StringLike) - only a token minted for an actual pull_request event can
# assume this role. A token from a manually-dispatched deploy.yml run (which
# carries an `environment:` claim instead, see deploy_role.tf) does not
# match this condition at all.

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_sub_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.project}-gha-plan-role"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

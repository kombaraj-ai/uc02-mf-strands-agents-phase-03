# --- deploy_role ---------------------------------------------------------
# One role per environment, assumed only by deploy.yml's jobs (which is
# workflow_dispatch-only - see .github/workflows/deploy.yml). Trust
# condition matches `sub = "...:environment:<env>"` exactly. GitHub only
# ever mints a token with an `environment:` claim for a job that explicitly
# declares `environment: <env>` in its YAML - a pull_request-triggered job
# never carries this claim (see plan_role.tf). This means even a
# misconfigured workflow can't get a PR run to assume a deploy role - the
# trust policy itself refuses it, independent of workflow logic or whatever
# GitHub Environment protection-rule settings happen to be configured.
#
# Permissions are scoped by resource-name-prefix ("${var.project}-<env>-*")
# everywhere the target service's ARN format supports it, following the
# exact precedent already established in
# modules/iam/lambda_execution_role.tf's CloudWatchLogsOwnFunctions
# statement - this is what keeps dev/staging/prod isolated from each other
# despite sharing one AWS account (see the project's own "Locked-in
# architecture decisions": isolation is by naming convention + separate
# Terraform state, not separate accounts - a deploy role that ignored this
# convention would quietly undermine that isolation for CI).
#
# A handful of actions are AWS-imposed exceptions that require
# `resources = ["*"]` regardless of scoping intent (ecr:GetAuthorizationToken,
# most OpenSearch Serverless control-plane actions, kms:CreateKey,
# Lambda event-source-mapping actions) - each is called out inline so it
# doesn't read as an oversight. A few S3 Vectors / AgentCore action names
# are best-effort against AWS's published docs and not yet independently
# verified by a real apply - flagged the same way this project already
# flags similar uncertainty elsewhere (see knowledge_base_role.tf's
# S3VectorsDataPlane comment, which documents a real wrong-action-name
# incident found only via a live AccessDenied). Expect to add a missing
# action here if a real `terraform apply` through this role surfaces one.

locals {
  environments = ["dev", "staging", "prod"]
}

data "aws_iam_policy_document" "deploy_trust" {
  for_each = toset(local.environments)

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
      values   = ["${local.github_sub_prefix}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = toset(local.environments)

  name               = "${var.project}-${each.key}-gha-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust[each.key].json
  tags               = local.common_tags
}

# Split into three documents (core infra / AgentCore+AI / compute+messaging)
# and attached as customer-managed policies rather than inline ones -
# discovered the hard way, 2026-07-14: AWS's 10,240-byte inline-policy limit
# is an AGGREGATE across ALL inline policies on a single role, not a
# per-document limit (confirmed against AWS's own IAM quotas doc - "the
# total aggregate policy size... per entity can't exceed" 10,240 bytes). A
# first attempt at a 2-way inline split still exceeded that aggregate once
# both documents co-existed on one role (this actually left dev fitting by
# luck, staging partially applied, and prod with NEITHER policy attached -
# a real broken-role incident, not just a plan-time problem). Customer
# managed policies have their own separate 6,144-byte limit that applies
# PER POLICY, not aggregated, and a role can attach up to 10 by default -
# so a 3-way split here has real headroom for the next several rounds of
# real-apply-driven fixes, unlike another inline split would have. No
# permissions or scoping logic changed by this restructure, just how each
# statement's JSON is packaged and attached.
data "aws_iam_policy_document" "deploy_permissions_core" {
  for_each = toset(local.environments)

  statement {
    sid    = "IamRolesAndInlinePolicies"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.key}-*"]
  }

  statement {
    sid       = "IamPassRoleForOwnServiceRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.key}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "lambda.amazonaws.com",
        "bedrock.amazonaws.com",
        "bedrock-agentcore.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "IamReadOidcProvider"
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [aws_iam_openid_connect_provider.github_actions.arn]
  }

  statement {
    sid    = "Ecr"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy", "ecr:GetLifecyclePolicy", "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration", "ecr:TagResource", "ecr:UntagResource",
      "ecr:ListTagsForResource", "ecr:DescribeImages", "ecr:BatchGetImage", "ecr:PutImage",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
      "ecr:SetRepositoryPolicy", "ecr:GetRepositoryPolicy", "ecr:DeleteRepositoryPolicy",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.project}-${each.key}-*"]
  }

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # AWS-imposed - this action has no resource-level scoping.
  }

  # deploy.yml's `promote` job crane-copies an image FROM dev's ECR repo INTO
  # this environment's own repo - the one deliberate crack in the
  # per-environment isolation convention above, required for build-once/
  # promote (see .github/workflows/deploy.yml). Read-only, and scoped to the
  # specific dev repo ARN, never wildcarded. dev's own role does not need
  # this statement at all (it only ever pushes to its own repo).
  dynamic "statement" {
    for_each = each.key == "dev" ? [] : [1]
    content {
      sid    = "CrossEnvReadDevEcrForPromotion"
      effect = "Allow"
      actions = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
      ]
      resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.project}-dev-agent-runtime"]
    }
  }

  statement {
    sid    = "DynamoDb"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:DescribeTable", "dynamodb:UpdateTable",
      "dynamodb:UpdateContinuousBackups", "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive", "dynamodb:UpdateTimeToLive",
      "dynamodb:TagResource", "dynamodb:UntagResource", "dynamodb:ListTagsOfResource",
    ]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${var.project}-${each.key}-*"]
  }

  statement {
    sid    = "S3ProjectBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:GetBucketLocation", "s3:GetBucketAcl", "s3:PutBucketAcl",
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion",
      "s3:ListBucket", "s3:ListBucketVersions",
      "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
      "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration",
      "s3:GetBucketNotification", "s3:PutBucketNotification",
      "s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPolicy", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy",
      "s3:GetBucketVersioning", "s3:PutBucketVersioning",
      "s3:GetBucketTagging", "s3:PutBucketTagging",
      # Read-only - aws_s3_bucket's Read function (resourceBucketRead in the
      # provider source) unconditionally calls all of these sub-config Get*
      # APIs on every refresh, regardless of whether this project declares
      # the corresponding block/sub-resource. GetBucketCORS was found first
      # via a real deploy-role-scoped apply (2026-07-14); the rest were
      # pre-empted by reading the provider's actual v6.54.0 source instead of
      # waiting to hit each one across a separate slow CI run. Names verified
      # against AWS's own IAM policy-generator action list, not guessed -
      # several (GetAccelerateConfiguration, GetReplicationConfiguration)
      # deliberately omit "Bucket" unlike their API operation name, matching
      # the same already-correct pattern as GetLifecycleConfiguration/
      # GetEncryptionConfiguration above.
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketLogging",
      "s3:GetReplicationConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:ForceDeleteBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-${each.key}-*",
      "arn:aws:s3:::${var.project}-${each.key}-*/*",
    ]
  }

  # Own environment's slice of the shared Terraform state bucket, scoped by
  # object-key prefix rather than the whole bucket - matches backend.hcl's
  # `key = "<env>/terraform.tfstate"` convention used everywhere else.
  statement {
    sid       = "S3StateBucketOwnEnvironment"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}/${each.key}/*"]
  }

  statement {
    sid       = "S3StateBucketListOwnEnvironment"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }

  # KMS CMKs - only actually created when this environment's use_cmk = true
  # (staging/prod, see environments/*/terraform.tfvars). kms:CreateKey has
  # no resource to scope to before the key exists, an AWS-imposed
  # constraint; the alias IS name-prefixable and scoped accordingly.
  statement {
    sid       = "KmsCreateKey"
    effect    = "Allow"
    actions   = ["kms:CreateKey"]
    resources = ["*"]
  }

  statement {
    sid    = "KmsManageOwnKeys"
    effect = "Allow"
    actions = [
      "kms:DescribeKey", "kms:EnableKeyRotation", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion",
      "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags",
      "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
    ]
    resources = [
      "arn:aws:kms:${var.aws_region}:${local.account_id}:key/*",
      "arn:aws:kms:${var.aws_region}:${local.account_id}:alias/${var.project}-${each.key}-*",
    ]
  }
}

data "aws_iam_policy_document" "deploy_permissions_agentcore" {
  for_each = toset(local.environments)

  # OpenSearch Serverless control plane (collection + security/access
  # policies). Most aoss control-plane actions don't support resource-level
  # ARN scoping at all (per AWS's own Service Authorization Reference for
  # aoss) - Resource = "*" here is an AWS-imposed constraint, not a scoping
  # choice. AOSS *data-plane* access (actually reading/writing vectors) is
  # controlled separately by the collection's own access policy, not by this
  # IAM policy - see the additional_data_access_principals tfvars change
  # this role's ARN also needs (infra/terraform/README.md's pass-2 section).
  statement {
    sid    = "OpenSearchServerlessControlPlane"
    effect = "Allow"
    actions = [
      "aoss:CreateCollection", "aoss:DeleteCollection", "aoss:UpdateCollection", "aoss:BatchGetCollection",
      "aoss:CreateSecurityPolicy", "aoss:UpdateSecurityPolicy", "aoss:GetSecurityPolicy",
      "aoss:DeleteSecurityPolicy", "aoss:ListSecurityPolicies",
      "aoss:CreateAccessPolicy", "aoss:UpdateAccessPolicy", "aoss:GetAccessPolicy",
      "aoss:DeleteAccessPolicy", "aoss:ListAccessPolicies",
      "aoss:TagResource", "aoss:UntagResource", "aoss:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # S3 Vectors control plane (dev-only backend today - see
  # environments/dev/variables.tf's vector_store_backend - scoped
  # identically for all three environments in case staging/prod ever opt
  # in). Data-plane action names are confirmed correct
  # (knowledge_base_role.tf's S3VectorsDataPlane comment documents the real
  # incident that found them); these control-plane names follow the same
  # AWS doc but are not yet independently verified against a live apply.
  statement {
    sid    = "S3VectorsControlPlane"
    effect = "Allow"
    actions = [
      "s3vectors:CreateVectorBucket", "s3vectors:DeleteVectorBucket", "s3vectors:GetVectorBucket",
      "s3vectors:PutVectorBucketPolicy", "s3vectors:GetVectorBucketPolicy", "s3vectors:DeleteVectorBucketPolicy",
      "s3vectors:CreateIndex", "s3vectors:DeleteIndex", "s3vectors:GetIndex", "s3vectors:ListIndexes",
      "s3vectors:TagResource", "s3vectors:UntagResource", "s3vectors:ListTagsForResource",
    ]
    resources = [
      "arn:aws:s3vectors:${var.aws_region}:${local.account_id}:bucket/${var.project}-${each.key}-*",
      "arn:aws:s3vectors:${var.aws_region}:${local.account_id}:bucket/${var.project}-${each.key}-*/index/*",
    ]
  }

  # Bedrock Knowledge Base. IDs are AWS-assigned, not name-prefixable like
  # ECR/DynamoDB/S3, so scoped to region/account rather than a resource-name
  # prefix - still meaningfully narrower than "*".
  statement {
    sid    = "BedrockKnowledgeBase"
    effect = "Allow"
    actions = [
      "bedrock:CreateKnowledgeBase", "bedrock:DeleteKnowledgeBase", "bedrock:GetKnowledgeBase", "bedrock:UpdateKnowledgeBase",
      "bedrock:CreateDataSource", "bedrock:DeleteDataSource", "bedrock:GetDataSource", "bedrock:UpdateDataSource",
      "bedrock:StartIngestionJob", "bedrock:GetIngestionJob", "bedrock:ListIngestionJobs",
      "bedrock:TagResource", "bedrock:UntagResource", "bedrock:ListTagsForResource",
    ]
    resources = ["arn:aws:bedrock:${var.aws_region}:${local.account_id}:knowledge-base/*"]
  }

  statement {
    sid       = "BedrockFoundationModelReadOnly"
    effect    = "Allow"
    actions   = ["bedrock:GetFoundationModel", "bedrock:ListFoundationModels"]
    resources = ["*"] # AWS-owned foundation models, not this account's resources.
  }

  # AgentCore Runtime/Gateway/Memory. AWS appends a random suffix to each
  # resource's ID (e.g. this project's real runtime ARN ends in
  # "-X1c5y89vze"), so these can't be name-prefix-scoped the way
  # ECR/DynamoDB/S3 are - scoped to resource-type/region/account instead.
  statement {
    sid    = "AgentCoreRuntimeGatewayMemory"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateAgentRuntime", "bedrock-agentcore:DeleteAgentRuntime",
      "bedrock-agentcore:GetAgentRuntime", "bedrock-agentcore:UpdateAgentRuntime", "bedrock-agentcore:ListAgentRuntimes",
      # CreateAgentRuntime implicitly provisions a default runtime endpoint
      # too - found via a real deploy-role-scoped apply, 2026-07-14, missing
      # entirely before this fix. Endpoints are sub-resources under a
      # runtime (runtime/<id>/runtime-endpoint/<name>), already covered by
      # the runtime/* wildcard below (unlike the un-wildcarded
      # workload-identity-directory ARN fixed earlier), so only the action
      # names needed adding here.
      "bedrock-agentcore:CreateAgentRuntimeEndpoint", "bedrock-agentcore:DeleteAgentRuntimeEndpoint",
      "bedrock-agentcore:GetAgentRuntimeEndpoint", "bedrock-agentcore:UpdateAgentRuntimeEndpoint",
      "bedrock-agentcore:ListAgentRuntimeEndpoints",
      "bedrock-agentcore:CreateGateway", "bedrock-agentcore:DeleteGateway",
      "bedrock-agentcore:GetGateway", "bedrock-agentcore:UpdateGateway",
      "bedrock-agentcore:CreateGatewayTarget", "bedrock-agentcore:DeleteGatewayTarget",
      "bedrock-agentcore:GetGatewayTarget", "bedrock-agentcore:UpdateGatewayTarget", "bedrock-agentcore:ListGatewayTargets",
      "bedrock-agentcore:CreateMemory", "bedrock-agentcore:DeleteMemory",
      "bedrock-agentcore:GetMemory", "bedrock-agentcore:UpdateMemory",
      "bedrock-agentcore:TagResource", "bedrock-agentcore:UntagResource", "bedrock-agentcore:ListTagsForResource",
    ]
    resources = [
      "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:runtime/*",
      "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:gateway/*",
      "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:memory/*",
    ]
  }

  # The Gateway provisions its OAuth credential dependency against the
  # account's single, shared workload-identity-directory/default resource -
  # not an environment-scoped resource the way runtime/gateway/memory above
  # are, so all three environments' deploy roles need this identically
  # (missing entirely before this fix - found via a real deploy-role-scoped
  # apply, 2026-07-14, "not authorized to perform:
  # bedrock-agentcore:CreateWorkloadIdentity"). The actual resource AWS
  # authorizes CreateWorkloadIdentity against is the sub-resource being
  # created (.../workload-identity-directory/default/workload-identity/<id>),
  # not the bare directory ARN - the first fix attempt granted only the
  # latter and still 403'd on a second real apply, so both patterns are
  # granted here.
  statement {
    sid    = "AgentCoreWorkloadIdentity"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateWorkloadIdentity", "bedrock-agentcore:GetWorkloadIdentity",
      "bedrock-agentcore:UpdateWorkloadIdentity", "bedrock-agentcore:DeleteWorkloadIdentity",
      "bedrock-agentcore:ListWorkloadIdentities",
      # CreateAgentRuntime auto-creates and tags a workload identity for
      # itself - missing entirely before this fix (found via a real
      # deploy-role-scoped apply, 2026-07-14). The
      # AgentCoreRuntimeGatewayMemory statement's TagResource grant doesn't
      # apply here since its resources list is runtime/gateway/memory ARNs,
      # not workload-identity ones.
      "bedrock-agentcore:TagResource", "bedrock-agentcore:UntagResource", "bedrock-agentcore:ListTagsForResource",
    ]
    resources = [
      "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default",
      "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default/workload-identity/*",
    ]
  }
}

data "aws_iam_policy_document" "deploy_permissions_compute" {
  for_each = toset(local.environments)

  statement {
    sid    = "Lambda"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
      "lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy",
      "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
      # aws_lambda_function's Read always checks the latest published version
      # via this action, regardless of whether publish = true is set (found
      # via a real deploy-role-scoped apply, 2026-07-14).
      "lambda:ListVersionsByFunction",
      # Also called unconditionally by Read for Zip-package-type functions in
      # commercial partitions (this project's case) - confirmed against the
      # provider's actual v6.54.0 source rather than waiting for a 4th
      # separate CI round-trip to discover it (found via a real
      # deploy-role-scoped apply, 2026-07-14).
      "lambda:GetFunctionCodeSigningConfig",
    ]
    resources = ["arn:aws:lambda:${var.aws_region}:${local.account_id}:function:${var.project}-${each.key}-*"]
  }

  # Event source mappings (SQS -> Lambda, kb-ingestion-sync) are identified
  # by an AWS-generated UUID, not the function name, so can't be
  # name-prefix-scoped - Resource = "*" here is an ARN-format constraint,
  # not a scoping choice.
  statement {
    sid    = "LambdaEventSourceMappings"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping", "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping", "lambda:UpdateEventSourceMapping", "lambda:ListEventSourceMappings",
      # The mapping resource is tagged like everything else this project
      # creates - missing entirely before this fix (found via a real
      # deploy-role-scoped apply, 2026-07-14).
      "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Sqs"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue", "sqs:DeleteQueue", "sqs:GetQueueAttributes", "sqs:SetQueueAttributes", "sqs:GetQueueUrl",
      "sqs:TagQueue", "sqs:UntagQueue", "sqs:ListQueueTags",
    ]
    resources = ["arn:aws:sqs:${var.aws_region}:${local.account_id}:${var.project}-${each.key}-*"]
  }

  statement {
    sid    = "CloudWatchLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
      "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
      "logs:TagLogGroup", "logs:UntagLogGroup", # legacy-API equivalents some provider versions still call
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${var.project}-${each.key}-*",
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/amc-orchestrator/${var.project}-${each.key}/*",
    ]
  }

  # logs:DescribeLogGroups doesn't support resource-level scoping the way the
  # actions above do - Terraform's provider always calls it as an account-wide
  # list (no exact log-group name), which AWS resolves against a generic
  # "log-group::log-stream:" ARN rather than any real log group's ARN, so it
  # only ever matches Resource = "*" (found via a real deploy-role-scoped
  # apply, 2026-07-14 - every prior apply used broader human credentials and
  # never exercised this).
  statement {
    sid       = "CloudWatchLogsDescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchDashboardAndAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards", "cloudwatch:GetDashboard",
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudwatch::${local.account_id}:dashboard/${var.project}-${each.key}-*",
      "arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${var.project}-${each.key}-*",
    ]
  }

  statement {
    sid    = "Sns"
    effect = "Allow"
    actions = [
      "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
      "sns:Subscribe", "sns:Unsubscribe", "sns:ListSubscriptionsByTopic",
      "sns:TagResource", "sns:UntagResource", "sns:ListTagsForResource",
    ]
    resources = ["arn:aws:sns:${var.aws_region}:${local.account_id}:${var.project}-${each.key}-*"]
  }
}

resource "aws_iam_policy" "deploy_core" {
  for_each = toset(local.environments)

  name   = "${var.project}-${each.key}-gha-deploy-core-policy"
  policy = data.aws_iam_policy_document.deploy_permissions_core[each.key].json
  tags   = local.common_tags
}

resource "aws_iam_policy" "deploy_agentcore" {
  for_each = toset(local.environments)

  name   = "${var.project}-${each.key}-gha-deploy-agentcore-policy"
  policy = data.aws_iam_policy_document.deploy_permissions_agentcore[each.key].json
  tags   = local.common_tags
}

resource "aws_iam_policy" "deploy_compute" {
  for_each = toset(local.environments)

  name   = "${var.project}-${each.key}-gha-deploy-compute-policy"
  policy = data.aws_iam_policy_document.deploy_permissions_compute[each.key].json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "deploy_core" {
  for_each = toset(local.environments)

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_core[each.key].arn
}

resource "aws_iam_role_policy_attachment" "deploy_agentcore" {
  for_each = toset(local.environments)

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_agentcore[each.key].arn
}

resource "aws_iam_role_policy_attachment" "deploy_compute" {
  for_each = toset(local.environments)

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_compute[each.key].arn
}

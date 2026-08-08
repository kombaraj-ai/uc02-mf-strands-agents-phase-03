data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Single source of truth for whether the OpenSearch Serverless collection
  # (and its access policy) should exist at all - spelled out once here so
  # collection creation and access-policy creation can never desync. false
  # only when the dev-only vector_store_backend = "s3_vectors" is selected.
  opensearch_enabled = var.vector_store_backend == "opensearch"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Claude/Nova for generation + the chosen embedding model for the
  # Knowledge Base - both need to be invokable by the runtime/KB roles.
  # amazon.nova-lite-v1:0 supports ON_DEMAND invocation directly (confirmed
  # via `bedrock:GetFoundationModel`), unlike current-generation Anthropic
  # models which require a cross-region inference profile - so a plain
  # foundation-model ARN is sufficient here, no inference-profile ARN needed.
  bedrock_model_arns = [
    "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}",
    "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embedding_model == "titan-v2" ? "amazon.titan-embed-text-v2:0" : "cohere.embed-multilingual-v3"}",
  ]
}

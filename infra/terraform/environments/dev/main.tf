# Composition order matters here - see each module's own comments for why.
# Rough shape: independent leaf resources first (dynamodb/ecr/s3/opensearch
# collection) -> iam (needs their ARNs) -> the access policy that needed iam
# and opensearch flipped the other way -> lambda-tools -> the two
# phase-gated modules (knowledge base, agent runtime) -> observability.

module "dynamodb" {
  source = "../../modules/dynamodb"

  name_prefix                    = local.name_prefix
  point_in_time_recovery_enabled = var.dynamodb_point_in_time_recovery
  deletion_protection_enabled    = var.dynamodb_deletion_protection
  use_cmk                        = var.use_cmk
  tags                           = local.common_tags
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix                = local.name_prefix
  untagged_image_expiry_days = var.ecr_untagged_image_expiry_days
  max_tagged_images          = var.ecr_max_tagged_images
  tags                       = local.common_tags
}

module "s3_kb_docs" {
  source = "../../modules/s3-kb-docs"

  name_prefix = local.name_prefix
  account_id  = data.aws_caller_identity.current.account_id
  use_cmk     = var.use_cmk
  tags        = local.common_tags
}

module "opensearch_serverless" {
  source = "../../modules/opensearch-serverless"

  enabled          = local.opensearch_enabled
  name_prefix      = local.name_prefix
  use_cmk          = var.use_cmk
  standby_replicas = var.opensearch_standby_replicas
  tags             = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  name_prefix                       = local.name_prefix
  aws_region                        = var.aws_region
  account_id                        = data.aws_caller_identity.current.account_id
  dynamodb_table_arn                = module.dynamodb.table_arn
  opensearch_collection_arn         = module.opensearch_serverless.collection_arn
  s3_vectors_bucket_arn             = var.enable_knowledge_base && var.vector_store_backend == "s3_vectors" ? module.s3_vectors[0].vector_bucket_arn : ""
  kb_docs_bucket_arn                = module.s3_kb_docs.bucket_arn
  ecr_repository_arn                = module.ecr.repository_arn
  bedrock_model_arns                = local.bedrock_model_arns
  lambda_tool_names                 = var.lambda_tool_names
  additional_data_access_principals = var.additional_data_access_principals
  tags                              = local.common_tags
}

module "opensearch_access_policy" {
  source = "../../modules/opensearch-access-policy"

  enabled         = local.opensearch_enabled
  collection_name = module.opensearch_serverless.collection_name
  principal_arns  = module.iam.data_access_principal_arns
  tags            = local.common_tags
}

module "lambda_tools" {
  source = "../../modules/lambda-tools"

  name_prefix                    = local.name_prefix
  tool_names                     = var.lambda_tool_names
  lambda_execution_role_arn      = module.iam.lambda_execution_role_arn
  dynamodb_table_name            = module.dynamodb.table_name
  opensearch_collection_endpoint = module.opensearch_serverless.collection_endpoint
  log_retention_days             = var.log_retention_days
  tags                           = local.common_tags

  depends_on = [module.opensearch_access_policy]
}

# --- Phase 2: vector index + knowledge base (see var.enable_knowledge_base) -
# vector_store_backend picks exactly one of the next two modules - see
# environments/dev/variables.tf and docs/architecture.md's "Environment
# lifecycle" section for why dev can opt into the cheaper S3 Vectors backend
# while staging/prod stay OpenSearch-only.
module "opensearch_index" {
  source = "../../modules/opensearch-index"
  count  = var.enable_knowledge_base && var.vector_store_backend == "opensearch" ? 1 : 0

  providers = {
    opensearch = opensearch
  }

  embedding_dimension = 1024

  depends_on = [module.opensearch_access_policy]
}

module "s3_vectors" {
  source = "../../modules/s3-vectors"
  count  = var.enable_knowledge_base && var.vector_store_backend == "s3_vectors" ? 1 : 0

  name_prefix         = local.name_prefix
  account_id          = data.aws_caller_identity.current.account_id
  embedding_dimension = 1024
  use_cmk             = var.use_cmk
  tags                = local.common_tags
}

module "knowledge_base" {
  source = "../../modules/knowledge-base"
  count  = var.enable_knowledge_base ? 1 : 0

  name_prefix               = local.name_prefix
  aws_region                = var.aws_region
  knowledge_base_role_arn   = module.iam.knowledge_base_role_arn
  docs_bucket_arn           = module.s3_kb_docs.bucket_arn
  vector_store_backend      = var.vector_store_backend
  opensearch_collection_arn = module.opensearch_serverless.collection_arn
  s3_vectors_index_arn      = var.vector_store_backend == "s3_vectors" ? module.s3_vectors[0].index_arn : ""
  embedding_model           = var.embedding_model
  tags                      = local.common_tags

  depends_on = [module.opensearch_index, module.s3_vectors]
}

module "kb_ingestion_sync" {
  source = "../../modules/kb-ingestion-sync"
  count  = var.enable_knowledge_base ? 1 : 0

  name_prefix             = local.name_prefix
  aws_region              = var.aws_region
  docs_bucket_id          = module.s3_kb_docs.bucket_name
  docs_bucket_arn         = module.s3_kb_docs.bucket_arn
  knowledge_base_id       = module.knowledge_base[0].knowledge_base_id
  data_source_id          = module.knowledge_base[0].data_source_id
  ingestion_sync_role_arn = module.iam.kb_ingestion_sync_role_arn
  log_retention_days      = var.log_retention_days
  tags                    = local.common_tags

  depends_on = [module.knowledge_base]
}

# --- Phase 3: agent runtime (see var.enable_agent_runtime) ----------------
module "agentcore_memory" {
  source = "../../modules/agentcore-memory"

  name_prefix       = local.name_prefix
  event_expiry_days = var.memory_event_expiry_days
  use_cmk           = var.use_cmk
  tags              = local.common_tags
}

module "agentcore_gateway" {
  source = "../../modules/agentcore-gateway"

  name_prefix      = local.name_prefix
  gateway_role_arn = module.iam.gateway_role_arn
  tags             = local.common_tags

  lambda_tools = {
    for name, arn in module.lambda_tools.function_arns :
    name => {
      lambda_arn  = arn
      description = "AMC ${name} tool (Terraform-provisioned placeholder - see modules/lambda-tools)"
    }
  }
}

module "agentcore_runtime" {
  source = "../../modules/agentcore-runtime"
  count  = var.enable_agent_runtime ? 1 : 0

  name_prefix         = local.name_prefix
  runtime_role_arn    = module.iam.runtime_role_arn
  container_image_uri = var.container_image_uri
  protocol            = var.runtime_protocol
  tags                = local.common_tags

  environment_variables = {
    ENVIRONMENT = var.environment
    # `Settings.effective_model_provider` only forces Bedrock when
    # `environment != "dev"` - by design, so a *local* dev run (CLI/API on a
    # dev machine) can default to Ollama. But this deployed Runtime container
    # also sets ENVIRONMENT=dev, and there is no Ollama reachable from AWS -
    # without this, the container tries to reach localhost:11434 and every
    # invocation fails with a connection error. Force Bedrock explicitly here;
    # staging/prod don't need this since `environment != "dev"` already forces
    # it for them.
    MODEL_PROVIDER = "bedrock"
    # Same reasoning as MODEL_PROVIDER above, for data instead of
    # generation: `Settings.effective_data_backend` only forces "aws"
    # (DynamoDB + Bedrock Knowledge Base) when `environment != "dev"`.
    # Without this, the deployed dev container falls back to DATA_BACKEND's
    # default of "local" (ephemeral SQLite/Chroma seeded with the same mock
    # values) instead of genuinely reading the DynamoDB table / Knowledge
    # Base this module provisions - easy to miss in a smoke test since the
    # mock data is byte-for-byte identical either way.
    DATA_BACKEND                   = "aws"
    DYNAMODB_TABLE_NAME            = module.dynamodb.table_name
    OPENSEARCH_COLLECTION_ENDPOINT = module.opensearch_serverless.collection_endpoint
    BEDROCK_KNOWLEDGE_BASE_ID      = var.enable_knowledge_base ? module.knowledge_base[0].knowledge_base_id : ""
    GATEWAY_URL                    = module.agentcore_gateway.gateway_url
    MEMORY_ID                      = module.agentcore_memory.memory_id
    BEDROCK_MODEL_ID               = var.bedrock_model_id
    AWS_REGION                     = var.aws_region
  }
}

module "observability" {
  source = "../../modules/observability"

  name_prefix         = local.name_prefix
  aws_region          = var.aws_region
  dynamodb_table_name = module.dynamodb.table_name
  lambda_function_names = concat(
    values(module.lambda_tools.function_names),
    var.enable_knowledge_base ? [module.kb_ingestion_sync[0].lambda_function_name] : [],
  )
  kb_ingestion_dlq_name = var.enable_knowledge_base ? module.kb_ingestion_sync[0].dlq_name : ""
  alarm_email           = var.alarm_email
  log_retention_days    = var.log_retention_days
  tags                  = local.common_tags
}

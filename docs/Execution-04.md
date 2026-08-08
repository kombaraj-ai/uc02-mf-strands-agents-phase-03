# User Guide: AMC RFP & Portfolio Insight Orchestrator — Phase 03 (DEV) - CI/CD

This guide walks through deploying and running the AMC RFP & Portfolio Insight Orchestrator
**entirely on AWS**, from an account with zero pre-existing resources, using the Phase 03
GitHub Actions CI/CD pipeline. It does not use, and does not require, a local LLM — every
query is served by **Amazon Bedrock** (via Bedrock AgentCore Runtime), not Ollama. If you
are looking for the abbreviated map of this same territory, see
[`user_guide.md`](user_guide.md); this document goes step by step, parameter by parameter.

For the *design* rationale (why OIDC, why build-once/promote, why no required-reviewer
gate, why three apply passes) see [`architecture.md`](architecture.md#phase-03--cicd-github-actions)
and [`infra/terraform/README.md`](../infra/terraform/README.md). This guide is the
*operational* companion — what to click/run, in what order, with what values.

---

## Overview of what gets deployed

![Phase 03 CI/CD flow](Phase-03.png)

Every environment applies in **up to three Terraform passes**
(`enable_knowledge_base`, `enable_agent_runtime`) because several resources
genuinely cannot exist before their prerequisites do. `deploy.yml` automates
all three passes behind one `workflow_dispatch` per environment; you do not
run `terraform apply` by hand except for the one-time bootstrapping steps
below.

---

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| An AWS account, admin (or near-admin) IAM credentials for the **one-time** local setup | You apply `bootstrap/` and `github-oidc/` locally, once, before CI can do anything | `aws sts get-caller-identity` |
| **Bedrock model access** granted for `amazon.nova-lite-v1:0` and the Titan V2 embedding model, in your target region | Account-level opt-in in the Bedrock console (Model access page) — Terraform cannot grant this | Bedrock console → Model access → both show `Access granted` |
| [Terraform](https://developer.hashicorp.com/terraform) **v1.15.7** (pinned: `>= 1.15.7, < 2.0.0`) | Used for the two one-time local applies (`bootstrap/`, `github-oidc/`) | `terraform version` |
| A GitHub repository you own or administer, with this code pushed to `main` | CI/CD runs from GitHub Actions against this repo | `git remote -v` |
| GitHub repo admin access (Settings → Environments, Secrets and variables) | You create three GitHub Environments and set variables by hand (deliberately not Terraform-managed — see [`ci_cd_runbook.md`](ci_cd_runbook.md)) | — |
| `aws` CLI v2, `docker`, and `boto3` (or the AWS Console) for post-deploy smoke testing | Verifying the deployed Runtime and uploading Knowledge Base documents | `aws --version`, `docker --version` |
| **No Ollama, no local GPU/CPU LLM, nothing to `ollama pull`.** | Every query, in every environment, is served by Bedrock (`amazon.nova-lite-v1:0` by default) | — |

> **Note on the AWS CLI**: the version bundled in some dev shells is too old to
> have `bedrock-agentcore` subcommands (used to invoke the deployed Runtime
> directly). Use the `boto3` script in [Testing the deployed Runtime](#testing-the-deployed-agentcore-runtime)
> below, or the AWS Console's built-in Test tab, instead of the CLI for that
> one step.

---

## Setup

### 1. Get the code onto GitHub

If you're starting from this repo as a template, push it to your own GitHub
repository first (out of scope for this guide beyond the basic commands):

```powershell
git remote -v                       # confirm origin (or add your own)
git push -u origin main
```

Everything below assumes the repository lives at `https://github.com/<org>/<repo>` on
branch `main` — the OIDC trust policies in `infra/terraform/github-oidc/` are scoped
to that exact `org/repo`, so this must be done first.

### 2. Bootstrap the Terraform state backend (one-time, local)

This creates the S3 bucket every environment's Terraform state lives in. It has its
own local state (chicken-and-egg — it can't store its own state remotely before the
bucket exists):

```powershell
cd infra/terraform/bootstrap
terraform init
terraform plan       # review before applying — see the note below
terraform apply
terraform output state_bucket_name      # note this — every later backend.hcl needs it
terraform output state_bucket_region
```

> **If you're re-running this after a full prior teardown** (this account has been
> torn down to zero resources before, including this exact state bucket), the
> `bootstrap/` directory's local `terraform.tfstate` file may still believe the
> bucket exists even though it's genuinely gone from AWS. This is expected and
> harmless: `terraform plan`/`apply` refreshes against real AWS first, notices the
> bucket is actually missing, and plans a normal **create** — not an error, and not
> a destroy/recreate of anything else. If `terraform plan` shows anything other than
> a clean "N to add" for the bucket and its supporting resources (versioning,
> encryption, public-access block), stop and re-check rather than applying blind.

### 3. Apply the GitHub OIDC identity module (one-time, local)

This is the one piece of CI infrastructure that **cannot bootstrap itself** — GitHub
Actions can't create the very IAM role it needs to authenticate to AWS, so this one
apply is always done by hand, with your own credentials, before either workflow can
do anything beyond `pr-validate.yml`'s no-credentials jobs:

```powershell
cd infra/terraform/github-oidc
Copy-Item backend.hcl.example backend.hcl
Copy-Item terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
github_org        = "<your-github-org-or-username>"
github_repo       = "<your-repo-name>"
state_bucket_name = "<state_bucket_name from step 2>"
```

Edit `backend.hcl`:

```hcl
bucket = "<state_bucket_name from step 2>"
key    = "github-oidc/terraform.tfstate"
region = "us-east-1"
```

Then:

```powershell
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
terraform output plan_role_arn
terraform output deploy_role_arns
```

Keep all four output values (`plan_role_arn`, and `deploy_role_arns["dev"]` /
`["staging"]` / `["prod"]`) — you need them in step 4.

This creates: the GitHub OIDC provider (`token.actions.githubusercontent.com`), one
shared **read-only** `plan` role (trusted only for `pull_request`-triggered tokens,
used by `pr-validate.yml`), and three per-environment **write-scoped** `deploy-<env>`
roles (each trusted only for a token asserting `environment:<env>` — i.e. only a job
that explicitly declares `environment: dev/staging/prod` can assume it, so a
PR-triggered run never can).

### 4. Create the three GitHub Environments

In the repo: **Settings → Environments** → **New environment**, create exactly
`dev`, `staging`, `prod` (names must match exactly — they're baked into both the
OIDC trust policies and `deploy.yml`'s `environment:` inputs). For **each** one:

- **Deployment branches**: restrict to `main` only. This is the actual safety net
  against an accidental deploy from a feature branch, since there's deliberately no
  required-reviewer gate (see the box below).
- **No required reviewers.** GitHub does not let the user who triggered a run approve
  their own deployment — on a single-maintainer project this would deadlock every
  staging/prod deploy. The manual `workflow_dispatch` trigger + OIDC role scoping +
  the branch restriction above are the safety net instead.

### 5. Set repo-level and per-Environment GitHub Actions variables

**Settings → Secrets and variables → Actions → Variables tab.**

Repo-level (top of that page, applies everywhere — used only by `pr-validate.yml`'s
`tf-plan` job, which deliberately never declares an `environment:`):

| Variable | Value |
|---|---|
| `AWS_PLAN_ROLE_ARN` | `plan_role_arn` from step 3 |
| `TF_STATE_BUCKET` | `state_bucket_name` from step 2 |

Per-Environment (open each of the three Environments created in step 4, add inside
each one — same variable **name**, different **value** per Environment):

| Environment | `AWS_DEPLOY_ROLE_ARN` value |
|---|---|
| `dev` | `deploy_role_arns["dev"]` from step 3 |
| `staging` | `deploy_role_arns["staging"]` from step 3 |
| `prod` | `deploy_role_arns["prod"]` from step 3 |

At this point CI/CD is fully wired. Nothing has touched application AWS resources
yet — only the CI identity itself exists.

---

## Configuration reference

The application never reads `os.getenv` directly — every setting goes through
`Settings` (`config/settings.py`). Two settings resolve differently in DEV vs.
STAGING/PROD:

- `effective_model_provider` — always `bedrock` when `environment != "dev"`.
- `effective_data_backend` — always `aws` (DynamoDB + Bedrock Knowledge Base) when
  `environment != "dev"`.

Because this guide only deploys to AWS, every environment the guide touches uses
Bedrock for generation and, in staging/prod, AWS for data. The table below lists
every setting relevant to a Bedrock/AWS deployment (Ollama-only fields are omitted —
they play no role here):

| Variable | Default | Purpose |
|---|---|---|
| `ENVIRONMENT` | `dev` | `dev` \| `staging` \| `prod`. Set automatically by Terraform on the deployed container (`ENVIRONMENT = var.environment`). |
| `MODEL_PROVIDER` | `ollama` | Forced to `bedrock` by Terraform for the **dev** container specifically (`environments/dev/main.tf`'s `environment_variables`), since `effective_model_provider` only auto-forces Bedrock when `environment != "dev"`. staging/prod don't need this override — `environment != "dev"` already forces it for them. |
| `BEDROCK_MODEL_ID` | `anthropic.claude-3-5-sonnet-20241022-v2:0` (code default — **end-of-life**, do not use) | All three environments' committed `terraform.tfvars` override this to `amazon.nova-lite-v1:0` (`ON_DEMAND`-invokable, no inference-profile IAM complexity, confirmed sufficient for this project's structured-output need). |
| `AWS_REGION` | `us-east-1` | Region for both Bedrock and every other AWS call. Set from `var.aws_region`. |
| `DATA_BACKEND` | `local` | `local` \| `aws`. Forced to `aws` by Terraform for the **dev** container specifically (`environments/dev/main.tf`'s `environment_variables`, mirroring the `MODEL_PROVIDER` override), since `effective_data_backend` only auto-forces `aws` when `environment != "dev"`. staging/prod don't need this override — `environment != "dev"` already forces it for them. |
| `DYNAMODB_TABLE_NAME` | `""` | Set automatically from `module.dynamodb.table_name`. |
| `BEDROCK_KNOWLEDGE_BASE_ID` | `""` | Set automatically from `module.knowledge_base[0].knowledge_base_id` — empty string until `enable_knowledge_base = true` has been applied. |
| `MAX_COMPLIANCE_ATTEMPTS` | `3` | Graceful cap on `compliance_check` re-runs before forced escalation. Not overridden by Terraform; change via a code-level default if ever needed. |
| `GRAPH_EXECUTION_TIMEOUT_SECONDS` | `300` | Hard graph-level timeout (seconds, not ms). |
| `LOG_LEVEL` / `LOG_FORMAT` | `DEBUG` / `json` | Structured logging; CloudWatch Logs captures container stdout regardless. |

None of these need to be set by you directly for a deployed environment — Terraform
sets the AWS-sourced ones (`DYNAMODB_TABLE_NAME`, `BEDROCK_KNOWLEDGE_BASE_ID`,
`GATEWAY_URL`, `MEMORY_ID`, `BEDROCK_MODEL_ID`, `AWS_REGION`) directly as the
container's process environment variables at deploy time — no `.env` file is baked
into the image (see the `Dockerfile`'s own comment on this).

### ✅ Fixed: dev's deployed container now sets `DATA_BACKEND=aws`

`infra/terraform/environments/dev/main.tf`'s `agentcore_runtime` module sets both
`MODEL_PROVIDER = "bedrock"` and `DATA_BACKEND = "aws"` explicitly in its
`environment_variables` block (each with a comment explaining why: both
`effective_model_provider` and `effective_data_backend` only auto-force their
AWS-backed value when `environment != "dev"`, and the deployed container's own
`ENVIRONMENT` is `"dev"` — so without an explicit override, the dev container would
otherwise fall back to Ollama / local SQLite-Chroma, neither of which is reachable
or meaningful in a deployed AWS container). staging/prod never needed either
override — their `ENVIRONMENT` unconditionally forces both to their AWS-backed
values already.

This previously caused a real, easy-to-miss gap: an earlier build of this module
only had the `MODEL_PROVIDER` override, so dev's deployed Runtime silently fell back
to an ephemeral local SQLite/Chroma store seeded with the same mock fund values —
the numbers returned looked identical (the mock data is byte-for-byte the same in
both stores), which is exactly what made it easy to miss in a smoke test. Both
overrides are now present as of this guide's current revision — no action needed
from you here, this section is left in as a record of the gap in case you're
diffing against an older checkout.

---

## Terraform variables (parameters)

Each environment's `infra/terraform/environments/<env>/terraform.tfvars` controls
its own deploy. These are the parameters you edit via PR before each
`deploy.yml` dispatch — never edited by CI itself.

| Variable | dev | staging | prod | Meaning |
|---|---|---|---|---|
| `aws_region` | `us-east-1` | `us-east-1` | `us-east-1` | Target region for every resource. |
| `project` | `amc-orchestrator` | same | same | Naming prefix for all resources. |
| `environment` | `dev` | `staging` | `prod` | Fixed per root module (validation error if changed). |
| `enable_knowledge_base` | `true`* | `false` | `false` | Phased-apply gate — pass 2. Requires the vector index/collection to exist first. |
| `enable_agent_runtime` | `true`* | `false` | `false` | Phased-apply gate — pass 3. Requires a real image already pushed to ECR. |
| `container_image_uri` | `""` (supplied via `-var` at apply time by `deploy.yml`, never committed) | `""` | `""` | Full ECR image URI + tag. Required only when `enable_agent_runtime = true`. |
| `vector_store_backend` | `s3_vectors` (dev-only option) | `opensearch` (locked) | `opensearch` (locked) | Which vector store backs the Knowledge Base. `s3_vectors` creates **zero** OpenSearch resources — cheapest option, dev-only. |
| `use_cmk` | `false` | `true` | `true` | Customer-managed KMS keys vs. AWS-managed encryption. |
| `opensearch_standby_replicas` | `DISABLED` | `ENABLED` | `ENABLED` | OpenSearch Serverless HA posture (only relevant if `vector_store_backend = opensearch`). |
| `dynamodb_point_in_time_recovery` | `false` | `true` | `true` | DynamoDB PITR backups. |
| `dynamodb_deletion_protection` | `false` | `true` | `true` | Prevents accidental table deletion. |
| `log_retention_days` | `14` | `90` | `365` | CloudWatch Logs retention. |
| `memory_event_expiry_days` | `14` | `30` | `90` | AgentCore Memory event TTL. |
| `ecr_untagged_image_expiry_days` | `7` | `14` | `30` | ECR lifecycle policy. |
| `ecr_max_tagged_images` | `10` | `20` | `30` | ECR lifecycle policy — keeps only the N most recent tagged images. |
| `alarm_email` | `""` | `""` | `""` (set before go-live) | Subscribes an email to the CloudWatch alarm SNS topic. `""` creates the topic/alarms but subscribes nobody. |
| `bedrock_model_id` | `amazon.nova-lite-v1:0` | same | same | Bedrock model for generation. The code-level default (an old Claude model) is end-of-life — every environment's tfvars already overrides it. |
| `embedding_model` | `titan-v2` | same | same | Embedding model for the Knowledge Base. |
| `runtime_protocol` | `HTTP` | same | same | AgentCore Runtime invocation protocol. |
| `additional_data_access_principals` | applier ARN + `deploy-dev` role ARN | `[]` (fill in `deploy-staging` role ARN before pass 2) | `[]` (fill in `deploy-prod` role ARN before pass 2) | ARNs granted AOSS data-plane access — only relevant when `vector_store_backend = opensearch`. Not needed for `s3_vectors`. |

\* dev's committed tfvars currently has both phased-apply gates already set to
`true` (left that way from a prior teardown-and-reset cycle) — meaning a single
`deploy.yml` dispatch for `environment=dev` now runs **all three passes in one go**
against a clean account (see [Step-by-step deployment](#step-by-step-deployment)
below — the `ensure-ecr` job creates the ECR repo first specifically so this works
cold). If you'd rather ramp up incrementally, set both back to `false` in a PR
before your first dispatch and follow the three-pass sequence manually.

### `deploy.yml` workflow inputs

| Input | Type | Required | Meaning |
|---|---|---|---|
| `environment` | choice: `dev` / `staging` / `prod` | yes | Target environment for this run. |
| `image_tag` | string | required for staging/prod when `promote_image=true`; ignored for dev | The exact git-SHA tag, already built and pushed to **dev's** ECR repo by a prior dev dispatch, to promote byte-for-byte into staging/prod. Never use `latest`. |
| `promote_image` | boolean (default `true`) | no | Set `false` for a staging/prod pass-1/pass-2-only apply where no image is involved yet (`enable_agent_runtime` still `false`). |

---

## Mock fund data

Four funds are seeded (idempotently) into whichever data backend is active — SQLite
locally, DynamoDB once deployed and (per the Known Issues note above) actually wired
up in dev:

| Ticker | Name | Category | NAV | Alpha | Beta | Sharpe | Std Dev | Sortino | R² | 1Y Return | 3Y Return |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `EQG1` | Global Equity Growth Fund | Largecap | 145.20 | 1.20 | 1.05 | 1.15 | 14.20% | 1.45 | 0.92 | 15.4% | 12.1% |
| `SMC3` | Alpha Prime Smallcap Direct Fund | Smallcap | 88.40 | 4.50 | 1.35 | 1.30 | 22.80% | 1.68 | 0.78 | 28.6% | 18.4% |
| `INC2` | Fixed Income Core Bond Fund | Debt/Conservative | 52.10 | 0.40 | 0.35 | 0.95 | 4.10% | 1.10 | 0.15 | 6.2% | 5.8% |
| `BLN4` | Balanced Conservative Wealth Fund | Hybrid | 112.75 | 0.85 | 0.75 | 1.05 | 9.50% | 1.25 | 0.85 | 11.2% | 9.5% |

`SMC3` is the deliberately volatile/high-risk fund used to exercise the compliance
loop — its high Beta/Std Dev and 28.6% 1-year return make it an easy target for a
"guarantee this will continue" bait question (see [Example 2](#example-2--the-compliance-loop-bait-scenario-smc3)
below). Matching manager-commentary narrative for each fund is the same text seeded
into Chroma locally and checked into the repo as standalone files for Knowledge Base
ingestion: [`docs/mock-data/`](mock-data/) (`doc_eqg1.txt`, `doc_smc3.txt`,
`doc_inc2.txt`, `doc_bln4.txt`).

---

## Step-by-step deployment

Everything in [Setup](#setup) above (bootstrap, github-oidc, GitHub Environments/
variables) is a **one-time** prerequisite. From here on, every action is either an
automatic PR check or a `deploy.yml` dispatch — no local `terraform apply` needed
for the application environments themselves.

### Step 1 — Open a PR and confirm `pr-validate.yml` passes

Any change to `main` goes through a PR first. `pr-validate.yml` runs automatically
and, for Terraform changes, posts a `terraform plan` as a PR comment per environment
(using the read-only `plan` role — never mutates AWS). Merge once green.

### Step 2 — Deploy `dev`

**Actions tab → Deploy → Run workflow** → `environment = dev` (leave `image_tag`/
`promote_image` at their defaults — they're a promote-only concept, irrelevant to
dev, which always builds fresh).

Or via CLI (if you have `gh` installed):

```powershell
gh workflow run deploy.yml -f environment=dev
```

This runs, in order:

1. **`ensure-ecr`** — `terraform apply -target=module.ecr` (idempotent; creates the
   ECR repo on a cold account, no-ops if it already exists).
2. **`build-and-push`** — builds the Docker image (`linux/arm64`, via QEMU
   emulation on the standard runner), tags it with the full commit SHA, pushes to
   dev's ECR repo.
3. **`terraform-apply`** — resolves the just-pushed image URI and runs
   `terraform apply -var="container_image_uri=..."` against dev's full tfvars.
   Since dev's tfvars already has `enable_knowledge_base = true` and
   `enable_agent_runtime = true` committed, **this one dispatch provisions all
   three passes** — IAM, DynamoDB, ECR, S3 docs bucket, Lambda stubs, Gateway,
   Memory, observability, the S3 Vectors bucket/index (dev's `vector_store_backend`),
   the empty Knowledge Base + ingestion-sync pipeline, and the Agent Runtime itself.

Expect this run to take several minutes (mostly the Docker build/push and the
AgentCore Runtime's own provisioning time). Watch it in the Actions tab.

**Do not skip Step 3 below** — the Knowledge Base is created empty; without
uploading documents, `qual_narrative_pull` retrieval will legitimately find nothing
and the qual agent should say so honestly (see the Known Issues item in
`CLAUDE.md`/`architecture.md` about a case where it didn't — worth verifying on your
own deploy).

### Step 3 — Upload the initial Knowledge Base documents

Terraform only ever creates an **empty** Knowledge Base — it never uploads a
document itself. The first upload is always a manual/CI step; every upload or
deletion *after* that auto-syncs via the `kb-ingestion-sync` pipeline (S3 event →
SQS → Lambda → `StartIngestionJob`), no manual ingestion call needed for anything
past this first pass.

```powershell
cd infra/terraform/environments/dev
Copy-Item backend.hcl.example backend.hcl   # fill in from bootstrap's output, if not already done
terraform init -backend-config=backend.hcl
$bucket = terraform output -raw kb_docs_bucket_name
aws s3 cp ..\..\..\..\docs\mock-data\ s3://$bucket/ --recursive --exclude "*" --include "doc_*.txt"
```

This queues an ingestion job automatically (fires within ~5 minutes, the pipeline's
batching window). To trigger and watch it immediately instead of waiting:

```powershell
$kbId = terraform output -raw knowledge_base_id
aws bedrock-agent list-data-sources --knowledge-base-id $kbId
# copy the "dataSourceId" from the output
$dataSourceId = "<paste dataSourceId>"
aws bedrock-agent start-ingestion-job --knowledge-base-id $kbId --data-source-id $dataSourceId
# copy the "ingestionJobId" from the output
$jobId = "<paste ingestionJobId>"
do {
  Start-Sleep -Seconds 5
  $job = aws bedrock-agent get-ingestion-job --knowledge-base-id $kbId --data-source-id $dataSourceId --ingestion-job-id $jobId | ConvertFrom-Json
  Write-Host $job.ingestionJob.status
} while ($job.ingestionJob.status -notin @("COMPLETE", "FAILED"))
$job.ingestionJob.statistics
```

Expect `numberOfDocumentsScanned: 4, numberOfNewDocumentsIndexed: 4,
numberOfDocumentsFailed: 0`.

> Running this manual trigger is harmless even if the automatic sync also fires
> around the same time — Bedrock treats the second call as a `ConflictException`,
> which the pipeline already handles as a success (ingestion is incremental, the
> already-running job covers the new files).

### Step 4 — Confirm the Runtime is ready

```powershell
$runtimeArn = terraform output -raw agent_runtime_arn
aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id ($runtimeArn -split '/')[-1] --region us-east-1
```

(If your AWS CLI is too old for `bedrock-agentcore-control`, check the AWS Console
instead: Bedrock console → AgentCore → Runtimes → your runtime → status should read
`READY`.)

### Step 5 — Testing the deployed AgentCore Runtime

Three ways, all Bedrock-only (no local server, no Ollama):

**Python/boto3** (quickest scripted option):

```python
import boto3, json

client = boto3.client("bedrock-agentcore", region_name="us-east-1")
resp = client.invoke_agent_runtime(
    agentRuntimeArn="<agent_runtime_arn output from Step 4>",
    payload=json.dumps({
        "prompt": "Please provide the current risk metrics for the Fixed Income "
                  "Core Bond Fund (INC2) and its macroeconomic strategy."
    }).encode("utf-8"),
    contentType="application/json",
)
print(resp["response"].read().decode("utf-8"))
```

**AWS Console**: Bedrock console → AgentCore → Runtimes → your runtime → **Test**
tab — a built-in invocation UI, no code needed.

**Streamlit UI, pointed at the deployed Runtime** (no local API server, no Ollama —
only the browser front-end runs locally):

```powershell
uv sync --group ui
uv run streamlit run src/amc_orchestrator/ui/streamlit_app.py
```

Opens at `http://localhost:8501`. In the sidebar, switch **Target** to **Deployed
AgentCore Runtime (AWS)**, enter your region and the `agent_runtime_arn` from Step 4
— a live **"Runtime READY"** badge confirms connectivity — then pick one of the
example queries below (or write your own) and click **Submit RFP**.

A ready-to-import Postman collection covering health checks and both a low-risk and
high-risk scenario is also available at
[`postman/amc_orchestrator.postman_collection.json`](postman/amc_orchestrator.postman_collection.json)
— note it targets the local FastAPI `/api/v1/rfp` route, not `invoke_agent_runtime`
directly, so it's only useful if you also run the local API server against
`MODEL_PROVIDER=bedrock`, which this AWS-only guide does not otherwise cover.

### Step 6 — Roll out `staging`, then `prod`

Both environments start with `enable_knowledge_base = false` and
`enable_agent_runtime = false` committed — a real three-pass rollout, not the
one-shot dev already has. Full sequence (see [`ci_cd_runbook.md`](ci_cd_runbook.md)
for the complete detail):

1. **Pass 1**: dispatch `deploy.yml` with `environment=staging`,
   `promote_image=false`. Creates IAM, ECR, DynamoDB, S3 docs bucket, Lambda stubs,
   Gateway, Memory, observability, and the OpenSearch Serverless collection
   (staging/prod are `opensearch`-only).
2. **PR**: set staging's `additional_data_access_principals` to the
   `deploy-staging` role ARN (from Setup step 3) and `enable_knowledge_base = true`.
   Merge after `pr-validate.yml` passes.
3. **Pass 2**: dispatch `deploy.yml` again, same inputs as step 1. Creates the
   OpenSearch vector index, the Knowledge Base, and the ingestion-sync pipeline.
4. Ensure a current image exists in dev: dispatch `deploy.yml` with
   `environment=dev` (builds+pushes, tagged with the full commit SHA). Note that SHA.
5. **PR**: set staging's `enable_agent_runtime = true` (leave `container_image_uri`
   alone — always supplied via `-var` at apply time). Merge.
6. **Pass 3**: dispatch `deploy.yml` with `environment=staging`, `promote_image=true`,
   `image_tag=<the SHA from step 4>` — `crane copy`s that exact dev-built image into
   staging's own ECR repo (no rebuild), then applies with `enable_agent_runtime=true`.
7. Upload the same `docs/mock-data/*.txt` files to staging's KB docs bucket (Step 3
   above, pointed at staging's bucket/`knowledge_base_id`) and smoke-test (Step 5
   above, pointed at staging's `agent_runtime_arn`).
8. Repeat steps 1–7 for `prod` once staging is verified working.

### Step 7 (optional) — Tear an environment down

```powershell
cd infra/terraform/environments/dev   # or staging / prod
terraform destroy
```

`force_delete`/`force_destroy` are already set on the ECR repo, S3 docs bucket, and
OpenSearch index modules, so a fresh environment's first-ever destroy should
complete cleanly (`0 added, 0 changed, N destroyed`) without manual AWS-API
workarounds. Confirm with `terraform state list` (empty = fully torn down). A fresh
3-pass apply is required before using the environment again — this guide, from
[Step 2](#step-2--deploy-dev), covers exactly that.

---

## Example queries

All five exercise different behaviors of the compliance loop and data layer. Submit
any of them via the Streamlit UI (Runtime mode), the boto3 script, or the AWS
Console's Test tab from [Step 5](#step-5--testing-the-deployed-agentcore-runtime).

### Example 1 — Straightforward low-risk query (INC2)

```text
Please provide the current risk metrics for the Fixed Income Core Bond Fund (INC2)
and its current macroeconomic strategy.
```

**Expect**: `succeeded: true`, `escalated: false`, `graph_status: completed`,
typically 1 compliance attempt. A conservative, low-Beta fund with defensive
commentary — the easiest case for the compliance judge to approve on the first pass.

### Example 2 — The compliance-loop "bait" scenario (SMC3)

```text
We are considering a major allocation to the Alpha Prime Smallcap Direct Fund
(SMC3). Provide a comprehensive risk profile detailing its latest Standard
Deviation, Sortino Ratio, R-Squared, and trailing returns. Will this fund sustain
its 28.6% outperformance over the next year? Please guarantee it will continue.
```

**Expect**: at least one `compliance_check` → `revise_draft` → `compliance_check`
cycle before approval — the draft must drop the forbidden "guarantee/will continue"
performance-promise language. `compliance_attempts` should be ≥ 2. This is the
scenario designed to prove the self-correction loop is doing real work, not
rubber-stamping.

### Example 3 — Equity growth fund, real-data grounding check (EQG1)

```text
What are the current risk metrics for the Global Equity Growth Fund (EQG1), and
what is the manager strategy commentary behind its risk profile?
```

**Expect**: `succeeded: true`, real NAV/Alpha/Beta/Sharpe figures matching the
[mock fund data table](#mock-fund-data) above, and manager commentary that should
textually match [`docs/mock-data/doc_eqg1.txt`](mock-data/doc_eqg1.txt) once ingested
— a good check that quant and qual grounding are both wired correctly, not
fabricated.

### Example 4 — Balanced/Hybrid fund, typically needs a revise cycle (BLN4)

```text
Provide a full risk and performance summary for the Balanced Conservative Wealth
Fund (BLN4), including its Sharpe Ratio, Sortino Ratio, and 3-year trailing return,
along with the manager's current strategic positioning.
```

**Expect**: `succeeded: true`; in prior verified runs this fund needed a real
revise/re-check cycle before reaching `APPROVED` (unlike EQG1's usual first-pass
approval), so `compliance_attempts` of 2–3 here is normal, not a sign of trouble.

### Example 5 — Unknown ticker, honesty check (no fabrication)

```text
Please provide the current risk metrics, including NAV, Alpha, and Beta, for the
Quantum Horizon Innovation Fund (ZZZ9).
```

**Expect**: a well-formed response (or graceful escalation) that **honestly reports
the ticker was not found**, rather than inventing plausible-sounding NAV/Alpha/Beta
figures for a fund that doesn't exist in the mock dataset. This is the one query in
this set designed to test the tool/data layer's error handling and the agents'
prompt adherence around fabrication, not the compliance loop.

---

## Troubleshooting

**A `deploy.yml` dispatch for `environment=dev` fails at `terraform-apply` with an
AOSS/OpenSearch authorization error.**
Only relevant if you've switched dev's `vector_store_backend` to `opensearch` — check
`additional_data_access_principals` includes the `deploy-dev` role ARN. Not
applicable with dev's default `s3_vectors` backend.

**`invoke_agent_runtime` returns a confident-sounding answer for a fund with no
ingested commentary yet.**
Expected until [Step 3](#step-3--upload-the-initial-knowledge-base-documents) has
completed and the ingestion job shows `COMPLETE` — the Knowledge Base starts empty.
If this still happens *after* documents are confirmed ingested (`Retrieve` API
returns real chunks), that is the known, previously-reported qual-agent fabrication
issue tracked in `CLAUDE.md`'s Phase 03 session log — not something this guide's
steps can work around.

**Staging/prod `deploy.yml` dispatch fails at the `promote` job with "image_tag is
required."**
`promote_image` defaults to `true`; either supply a real `image_tag` (a git SHA
already pushed to dev's ECR repo) or set `promote_image=false` for a pass-1/pass-2
apply that doesn't need an image yet.

**A fresh `environments/<env>` apply tries to create the Agent Runtime referencing an
image that doesn't exist.**
Only possible if `enable_agent_runtime = true` was left set from a prior teardown
while the ECR repo was actually empty/deleted. `deploy.yml`'s `ensure-ecr` job
(`terraform apply -target=module.ecr`, idempotent) runs before `build-and-push` for
exactly this reason — dispatching through `deploy.yml` (not a raw local
`terraform apply`) avoids this failure mode entirely.

**`terraform plan`/`apply` fails locally with missing credentials.**
Local applies (bootstrap, github-oidc) need real AWS credentials
(`aws configure` / an SSO profile). `terraform validate` (schema/type checking) needs
none — that's the split `pr-validate.yml` itself uses.

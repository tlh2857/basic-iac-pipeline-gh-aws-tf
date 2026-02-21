# basic-iac-pipeline-gh-aws-tf
Guide to help you deploy a basic IaC pipeline using github, terraform, AWS (with DDB and S3 backend)

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Step 1: AWS Bootstrap (One-Time Setup)](#step-1-aws-bootstrap-one-time-setup)
- [Step 2: GitHub Repository Setup](#step-2-github-repository-setup)
- [Step 3: Terraform Configuration](#step-3-terraform-configuration)
- [Step 4: GitHub Actions Workflows](#step-4-github-actions-workflows)
- [Step 5: Yor Automated Tagging](#step-5-yor-automated-tagging)
- [Step 6: Testing the Pipeline](#step-6-testing-the-pipeline)
- [How It All Works Together](#how-it-all-works-together)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## Overview

This guide walks you through building a **complete Infrastructure-as-Code (IaC) pipeline** that:

| Component | Purpose |
|-----------|---------|
| **GitHub** | Source control for Terraform code |
| **GitHub Actions** | CI/CD automation engine |
| **Terraform** | Infrastructure provisioning (deploys an S3 bucket) |
| **AWS S3** | Remote state storage + the resource we're deploying |
| **DynamoDB** | State locking (prevents concurrent modifications) |
| **Yor** | Automatic git-context tagging on IaC resources |

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         DEVELOPER                                │
│                                                                  │
│   1. Write Terraform code                                        │
│   2. Push to feature branch                                      │
│   3. Open Pull Request                                           │
└──────────────┬───────────────────────────────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────────────────────┐
│                        GITHUB                                    │
│                                                                  │
│  ┌─────────────┐    ┌──────────────────────────────────────┐     │
│  │  Repository  │───▶│       GitHub Actions Workflows       │     │
│  │             │    │                                      │     │
│  │ - main      │    │  On PR:                              │     │
│  │ - feature/* │    │    - Yor auto-tags resources         │     │
│  │             │    │    - terraform fmt -check            │     │
│  │             │    │    - terraform init                  │     │
│  │             │    │    - terraform validate              │     │
│  │             │    │    - terraform plan                  │     │
│  │             │    │    - Post plan to PR comment         │     │
│  │             │    │                                      │     │
│  │             │    │  On merge to main:                   │     │
│  │             │    │    - terraform apply -auto-approve   │     │
│  └─────────────┘    └──────────────┬───────────────────────┘     │
│                                    │                             │
└────────────────────────────────────┼─────────────────────────────┘
                                     │
                                     ▼
┌──────────────────────────────────────────────────────────────────┐
│                          AWS                                     │
│                                                                  │
│  ┌─────────────────────┐    ┌─────────────────────────────┐     │
│  │  S3: State Bucket   │    │  DynamoDB: State Lock Table │     │
│  │                     │    │                             │     │
│  │  terraform.tfstate  │    │  Prevents concurrent        │     │
│  │                     │    │  terraform apply            │     │
│  └─────────────────────┘    └─────────────────────────────┘     │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │                DEPLOYED RESOURCES                       │     │
│  │                                                         │     │
│  │  S3 Bucket: "my-demo-app-assets-<account-id>"           │     │
│  │    - Auto-tagged by Yor with git metadata               │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- **AWS Account** with admin access (or sufficient IAM permissions)
- **GitHub Account** with a new repository
- Basic familiarity with Git, AWS, and the terminal

---

## Step 1: AWS Bootstrap (One-Time Setup)

> ⚠️ This is the **only manual AWS step**. Everything after this is automated.

We need to create the S3 bucket and DynamoDB table that Terraform will use to store its **state file**. This is a chicken-and-egg problem — we use a simple script to bootstrap it.

### 1.1 Create the Bootstrap Script

Create a file called `bootstrap/main.tf`:

```hcl
# bootstrap/main.tf
# ===========================================
# RUN THIS LOCALLY ONCE, THEN NEVER AGAIN
# This creates the backend infrastructure
# that Terraform needs to manage its state.
# ===========================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Change to your preferred region
}

# Get current AWS account ID dynamically
data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "terraform-state-${local.account_id}"
  table_name  = "terraform-state-lock"
}

# ─── S3 Bucket for Terraform State ────────────────────────────
resource "aws_s3_bucket" "terraform_state" {
  bucket = local.bucket_name

  # Prevent accidental deletion of this critical bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "Terraform State Bucket"
    ManagedBy   = "bootstrap-terraform"
    Environment = "management"
  }
}

# Enable versioning so we can roll back state if something goes wrong
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest — it often contains sensitive data
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — state files should NEVER be public
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── DynamoDB Table for State Locking ─────────────────────────
# Prevents two CI runs from modifying state at the same time
resource "aws_dynamodb_table" "terraform_lock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST" # No cost when idle
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Terraform State Lock Table"
    ManagedBy   = "bootstrap-terraform"
    Environment = "management"
  }
}

# ─── Outputs ──────────────────────────────────────────────────
output "state_bucket_name" {
  description = "Use this value in your Terraform backend config"
  value       = aws_s3_bucket.terraform_state.id
}

output "lock_table_name" {
  description = "Use this value in your Terraform backend config"
  value       = aws_dynamodb_table.terraform_lock.name
}

output "aws_region" {
  description = "The AWS region used"
  value       = "us-east-1"
}
```

### 1.2 Run the Bootstrap

```bash
cd bootstrap/
terraform init
terraform plan
terraform apply
```

**Save the outputs** — you'll need them in Step 3:

```
state_bucket_name = "terraform-state-123456789012"
lock_table_name   = "terraform-state-lock"
aws_region        = "us-east-1"
```

### 1.3 Create an IAM User for GitHub Actions

Create a dedicated IAM user with **programmatic access** for the pipeline:

```bash
# Create the user
aws iam create-user --user-name github-actions-terraform

# Attach a policy (use a scoped-down policy in production!)
aws iam attach-user-policy \
  --user-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-user-policy \
  --user-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess

# Create access keys
aws iam create-access-key --user-name github-actions-terraform
```

> **Note:** In production, use **OIDC federation** instead of long-lived access keys. This guide uses access keys for simplicity. See [GitHub's OIDC docs](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services) for the production approach.

**Save the `AccessKeyId` and `SecretAccessKey`** from the output.

---

## Step 2: GitHub Repository Setup

### 2.1 Create Repository Structure

```
your-repo/
├── .github/
│   └── workflows/
│       ├── terraform.yml        # Main Terraform CI/CD pipeline
│       └── yor.yml              # Yor auto-tagging workflow
├── terraform/
│   ├── main.tf                  # Main infrastructure definitions
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Output values
│   ├── versions.tf              # Provider & backend configuration
│   └── terraform.tfvars         # Variable values
├── bootstrap/
│   └── main.tf                  # (from Step 1 — keep for reference)
├── .gitignore
└── README.md
```

### 2.2 Create `.gitignore`

```gitignore
# .gitignore

# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
crash.log
crash.*.log
*.tfvars.json
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraformrc
terraform.rc

# OS
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/
*.swp
*.swo

# Environment
.env
```

### 2.3 Configure GitHub Secrets

Go to your repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these secrets:

| Secret Name | Value |
|------------|-------|
| `AWS_ACCESS_KEY_ID` | From Step 1.3 |
| `AWS_SECRET_ACCESS_KEY` | From Step 1.3 |

---

## Step 3: Terraform Configuration

### 3.1 `terraform/versions.tf` — Provider & Backend

```hcl
# terraform/versions.tf
# ===========================================
# Terraform and provider version constraints,
# plus remote backend configuration.
# ===========================================

terraform {
  required_version = ">= 1.5.0"

  # ─── Remote State Backend ─────────────────────────────────
  # This tells Terraform to store its state file in S3
  # instead of locally. This is CRITICAL for team workflows
  # and CI/CD pipelines.
  backend "s3" {
    bucket         = "terraform-state-123456789012"  # ← Replace with YOUR bucket name from bootstrap
    key            = "demo-app/terraform.tfstate"     # Path within the bucket
    region         = "us-east-1"                      # ← Replace with YOUR region
    dynamodb_table = "terraform-state-lock"           # ← Replace with YOUR table name from bootstrap
    encrypt        = true                             # Encrypt state at rest
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Default tags applied to ALL resources created by this provider
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Pipeline    = "github-actions"
    }
  }
}
```

### 3.2 `terraform/variables.tf` — Input Variables

```hcl
# terraform/variables.tf
# ===========================================
# Input variables for the Terraform config.
# Values come from terraform.tfvars or
# environment variables.
# ===========================================

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project (used in resource naming and tagging)"
  type        = string
  default     = "demo-iac-pipeline"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "asset_bucket_name_suffix" {
  description = "Suffix for the S3 asset bucket name (will be prefixed with project name)"
  type        = string
  default     = "assets"
}
```

### 3.3 `terraform/main.tf` — The Infrastructure

```hcl
# terraform/main.tf
# ===========================================
# Main infrastructure definitions.
# This deploys an S3 bucket for storing
# application assets (images, files, etc.)
# ===========================================

# Get current AWS account ID for globally unique naming
data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project_name}-${var.asset_bucket_name_suffix}-${local.account_id}-${var.environment}"
}

# ─── S3 Bucket: Application Assets ───────────────────────────
resource "aws_s3_bucket" "app_assets" {
  bucket = local.bucket_name

  tags = {
    Name        = local.bucket_name
    Description = "Stores application static assets"
    # Yor will automatically add git tags below this line
  }
}

# Enable versioning — keeps history of every object version
resource "aws_s3_bucket_versioning" "app_assets" {
  bucket = aws_s3_bucket.app_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption by default
resource "aws_s3_bucket_server_side_encryption_configuration" "app_assets" {
  bucket = aws_s3_bucket.app_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block ALL public access — defense in depth
resource "aws_s3_bucket_public_access_block" "app_assets" {
  bucket = aws_s3_bucket.app_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule — automatically manage object storage costs
resource "aws_s3_bucket_lifecycle_configuration" "app_assets" {
  bucket = aws_s3_bucket.app_assets.id

  rule {
    id     = "transition-old-versions"
    status = "Enabled"

    # Move non-current versions to cheaper storage after 30 days
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    # Delete non-current versions after 90 days
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Upload a sample asset to prove the pipeline works end-to-end
resource "aws_s3_object" "sample_asset" {
  bucket       = aws_s3_bucket.app_assets.id
  key          = "hello.txt"
  content      = "Hello from Terraform! Deployed via GitHub Actions pipeline. 🚀"
  content_type = "text/plain"

  tags = {
    Name = "Sample Asset"
  }
}
```

### 3.4 `terraform/outputs.tf` — Output Values

```hcl
# terraform/outputs.tf
# ===========================================
# Outputs are displayed after terraform apply
# and can be referenced by other Terraform
# configs or scripts.
# ===========================================

output "bucket_name" {
  description = "Name of the deployed S3 asset bucket"
  value       = aws_s3_bucket.app_assets.id
}

output "bucket_arn" {
  description = "ARN of the deployed S3 asset bucket"
  value       = aws_s3_bucket.app_assets.arn
}

output "bucket_region" {
  description = "Region of the deployed S3 asset bucket"
  value       = aws_s3_bucket.app_assets.region
}

output "sample_asset_url" {
  description = "S3 URI of the sample uploaded asset"
  value       = "s3://${aws_s3_bucket.app_assets.id}/${aws_s3_object.sample_asset.key}"
}
```

### 3.5 `terraform/terraform.tfvars` — Variable Values

```hcl
# terraform/terraform.tfvars
# ===========================================
# Actual values for the variables.
# Adjust these for your project.
# ===========================================

aws_region               = "us-east-1"
project_name             = "demo-iac-pipeline"
environment              = "dev"
asset_bucket_name_suffix = "assets"
```

---

## Step 4: GitHub Actions Workflows

### 4.1 `terraform.yml` — Main CI/CD Pipeline

```yaml
# .github/workflows/terraform.yml
# ===========================================
# Terraform CI/CD Pipeline
#
# On Pull Request → Plan (and comment on PR)
# On Push to main → Apply
# ===========================================

name: "Terraform"

on:
  push:
    branches:
      - main
    paths:
      - "terraform/**"
      - ".github/workflows/terraform.yml"
  pull_request:
    branches:
      - main
    paths:
      - "terraform/**"
      - ".github/workflows/terraform.yml"

# Cancel in-progress runs for the same branch
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: true

# Required for the GitHub token to post PR comments
permissions:
  contents: read
  pull-requests: write

env:
  TF_VERSION: "1.5.7"
  TF_WORKING_DIR: "terraform"
  AWS_REGION: "us-east-1"

jobs:
  # ─────────────────────────────────────────────
  # JOB 1: Terraform Format, Validate, and Plan
  # Runs on every push and every PR
  # ─────────────────────────────────────────────
  terraform-plan:
    name: "Plan"
    runs-on: ubuntu-latest

    # Expose the plan exit code so the apply job can use it
    outputs:
      plan-exit-code: ${{ steps.plan.outputs.exitcode }}

    steps:
      # ── Check out the code ──────────────────
      - name: Checkout repository
        uses: actions/checkout@v4

      # ── Set up Terraform ────────────────────
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}
          terraform_wrapper: true  # Enables capturing output

      # ── Configure AWS Credentials ──────────
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      # ── Terraform Format Check ─────────────
      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check -recursive -diff
        working-directory: ${{ env.TF_WORKING_DIR }}
        continue-on-error: true

      # ── Terraform Init ─────────────────────
      - name: Terraform Init
        id: init
        run: terraform init -input=false
        working-directory: ${{ env.TF_WORKING_DIR }}

      # ── Terraform Validate ─────────────────
      - name: Terraform Validate
        id: validate
        run: terraform validate -no-color
        working-directory: ${{ env.TF_WORKING_DIR }}

      # ── Terraform Plan ─────────────────────
      - name: Terraform Plan
        id: plan
        run: |
          terraform plan \
            -input=false \
            -no-color \
            -detailed-exitcode \
            -out=tfplan
        working-directory: ${{ env.TF_WORKING_DIR }}
        continue-on-error: true
        # Exit codes: 0 = no changes, 1 = error, 2 = changes present

      # ── Post Plan to PR Comment ────────────
      - name: Comment Plan on PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            // Collect results from all steps
            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            // Find and delete previous bot comments to keep the PR clean
            const botComment = comments.find(comment =>
              comment.user.type === 'Bot' &&
              comment.body.includes('Terraform Plan Summary')
            );
            if (botComment) {
              await github.rest.issues.deleteComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: botComment.id,
              });
            }

            // Build the comment body
            const fmt = '${{ steps.fmt.outcome }}';
            const init = '${{ steps.init.outcome }}';
            const validate = '${{ steps.validate.outcome }}';
            const plan = '${{ steps.plan.outcome }}';
            const planExitCode = '${{ steps.plan.outputs.exitcode }}';

            const statusIcon = (status) => status === 'success' ? '✅' : '❌';
            const planStatus = planExitCode === '0' ? '💤 No changes'
                             : planExitCode === '2' ? '⚡ Changes detected'
                             : '❌ Error';

            const output = `## Terraform Plan Summary

            | Step | Status |
            |------|--------|
            | 🖌 Format | ${statusIcon(fmt)} \`${fmt}\` |
            | ⚙️ Init | ${statusIcon(init)} \`${init}\` |
            | 🔍 Validate | ${statusIcon(validate)} \`${validate}\` |
            | 📋 Plan | ${planStatus} |

            <details><summary>📝 Show Full Plan Output</summary>

            \`\`\`terraform
            ${{ steps.plan.outputs.stdout }}
            \`\`\`

            </details>

            *Pushed by: @${{ github.actor }}, Action: \`${{ github.event_name }}\`*
            *Commit: \`${{ github.sha }}\`*`;

            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: output
            });

      # ── Fail the job if plan had an error ──
      - name: Terraform Plan Status
        if: steps.plan.outputs.exitcode == 1
        run: exit 1

  # ─────────────────────────────────────────────
  # JOB 2: Terraform Apply
  # Only runs on push to main (after PR merge)
  # ─────────────────────────────────────────────
  terraform-apply:
    name: "Apply"
    runs-on: ubuntu-latest
    needs: terraform-plan
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'

    # Require manual approval in production environments
    # (Uncomment the 'environment' line below and configure
    #  an environment with protection rules in GitHub Settings)
    # environment: production

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Init
        run: terraform init -input=false
        working-directory: ${{ env.TF_WORKING_DIR }}

      - name: Terraform Apply
        run: terraform apply -input=false -auto-approve
        working-directory: ${{ env.TF_WORKING_DIR }}
```

---

## Step 5: Yor Automated Tagging

### What is Yor?

[**Yor**](https://github.com/bridgecrewio/yor) by Bridgecrew automatically tags your IaC resources with useful **git metadata** — who last modified the resource, which commit, which repo, etc. This is invaluable for:

- **Traceability:** Which commit created this resource?
- **Cost allocation:** Who owns this resource?
- **Drift detection:** Does the live resource match the code?

### 5.1 `yor.yml` — Yor Tagging Workflow

```yaml
# .github/workflows/yor.yml
# ===========================================
# Yor Automatic IaC Tagging
#
# When a PR is opened/updated, Yor scans
# Terraform files and adds git-context tags
# directly to the source code, then commits
# the changes back to the PR branch.
# ===========================================

name: "Yor Tagging"

on:
  pull_request:
    branches:
      - main
    paths:
      - "terraform/**"

permissions:
  contents: write
  pull-requests: write

jobs:
  yor:
    name: "Auto-Tag IaC Resources"
    runs-on: ubuntu-latest

    steps:
      # Check out with full history (Yor needs git context)
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          ref: ${{ github.head_ref }}
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      # Run Yor to tag all Terraform resources
      - name: Run Yor
        uses: bridgecrewio/yor-action@main
        with:
          directory: terraform
          tag_groups: "git"
          # tag_groups options:
          #   "git"  — yor_name, yor_trace, git_last_modified_by,
          #            git_last_modified_at, git_org, git_repo,
          #            git_commit, git_modifiers, git_file
          #   "code2cloud" — yor_name, yor_trace (minimal)
          #
          # You can also use "git,code2cloud" for all tags

      # Commit the tag changes back to the PR branch
      - name: Commit Yor tag changes
        run: |
          git config --global user.name "github-actions[bot]"
          git config --global user.email "github-actions[bot]@users.noreply.github.com"

          # Only commit if there are changes
          if [[ -n $(git status -s) ]]; then
            git add .
            git commit -m "🏷️ Update Yor tags [skip ci]"
            git push
            echo "✅ Yor tags committed and pushed."
          else
            echo "ℹ️ No Yor tag changes to commit."
          fi
```

### 5.2 What Yor Tags Look Like

After Yor runs, your `main.tf` resource blocks will be automatically updated with tags like this:

```hcl
resource "aws_s3_bucket" "app_assets" {
  bucket = local.bucket_name

  tags = {
    Name        = local.bucket_name
    Description = "Stores application static assets"

    # ──── Auto-generated by Yor ─────────────────
    yor_name             = "app_assets"
    yor_trace            = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    git_commit           = "abc1234def5678"
    git_file             = "terraform/main.tf"
    git_last_modified_at = "2024-01-15 14:30:22"
    git_last_modified_by = "your-email@example.com"
    git_modifiers        = "your-github-username"
    git_org              = "your-github-org"
    git_repo             = "your-repo-name"
  }
}
```

> **💡 `yor_trace`** is a unique UUID that stays constant across changes, creating a permanent link between the code and the deployed resource.

---

## Step 6: Testing the Pipeline

### 6.1 Initial Setup

```bash
# Clone your repo
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO

# Create the directory structure
mkdir -p .github/workflows terraform bootstrap

# Copy all the files from this guide into the appropriate locations
# (versions.tf, main.tf, variables.tf, outputs.tf, terraform.tfvars,
#  terraform.yml, yor.yml, .gitignore)

# Push the initial structure to main
git add .
git commit -m "🎉 Initial project structure"
git push origin main
```

### 6.2 Make a Change via Pull Request

```bash
# Create a feature branch
git checkout -b feature/initial-infrastructure

# The Terraform files should already be in place.
# If you want to make a change, try editing the sample asset:
# In terraform/main.tf, change the hello.txt content to something else.

git add .
git commit -m "✨ Add S3 asset bucket infrastructure"
git push origin feature/initial-infrastructure
```

### 6.3 Open a Pull Request

1. Go to your GitHub repository
2. Click **"Compare & pull request"**
3. Add a title: `Add S3 asset bucket infrastructure`
4. Click **"Create pull request"**

### 6.4 Watch the Magic Happen

You should see **two workflows** trigger:

```
┌─────────────────────────────────────────────────────┐
│  Pull Request: Add S3 asset bucket infrastructure   │
│                                                     │
│  Checks:                                            │
│  ✅ Yor Tagging — Auto-tags committed to branch     │
│  ✅ Terraform Plan — Plan posted as PR comment      │
│                                                     │
│  PR Comment:                                        │
│  ┌─────────────────────────────────────────────┐    │
│  │ ## Terraform Plan Summary                   │    │
│  │                                             │    │
│  │ | Step       | Status              |        │    │
│  │ |------------|---------------------|        │    │
│  │ | 🖌 Format   | ✅ success          |        │    │
│  │ | ⚙️ Init    | ✅ success          |        │    │
│  │ | 🔍 Validate| ✅ success          |        │    │
│  │ | 📋 Plan    | ⚡ Changes detected |        │    │
│  │                                             │    │
│  │ ▶ Show Full Plan Output                     │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### 6.5 Merge and Deploy

1. Review the plan in the PR comment
2. Review the Yor tag changes (new commit on the branch)
3. Click **"Merge pull request"**
4. The **Terraform Apply** job triggers automatically on `main`
5. Your S3 bucket is now deployed! 🎉

### 6.6 Verify the Deployment

```bash
# List the bucket
aws s3 ls | grep demo-iac-pipeline

# Read the sample asset
aws s3 cp s3://demo-iac-pipeline-assets-YOUR_ACCOUNT_ID-dev/hello.txt -

# Check the tags on the bucket
aws s3api get-bucket-tagging \
  --bucket demo-iac-pipeline-assets-YOUR_ACCOUNT_ID-dev
```

---

## How It All Works Together

```
 Developer                   GitHub                        AWS
 ─────────                   ──────                        ───

 1. Write code
    └──push──────────▶ Feature Branch
                           │
 2. Open PR                │
    └──────────────▶ Pull Request Created
                           │
                    ┌──────┴──────────────┐
                    │                     │
                    ▼                     ▼
              Yor Workflow          Terraform Workflow
              ┌──────────┐         ┌──────────────┐
              │ Scan .tf  │         │ fmt check    │
              │ Add tags  │         │ init         │
              │ Commit    │─push──▶ │ validate     │
              │ back      │  tags   │ plan ────────│──▶ Read state from S3
              └──────────┘         │ comment PR   │    Lock DynamoDB
                                   └──────────────┘    Unlock DynamoDB
                    │
 3. Review plan     │
    in PR comment   │
                    │
 4. Approve & Merge │
    └──────────────▶ Push to main
                           │
                           ▼
                    Terraform Workflow
                    ┌──────────────┐
                    │ init         │
                    │ apply ───────│──────────────▶ Create S3 bucket
                    │              │                Write state to S3
                    └──────────────┘                Lock/Unlock DynamoDB
                                                         │
                                                         ▼
                                                   ✅ S3 Bucket Live!
                                                   Tagged with Yor metadata
                                                   Encrypted, versioned,
                                                   no public access
```

---

## Cleanup

### Destroy the Deployed Resources

```bash
cd terraform/

# Destroy the S3 bucket and objects
terraform init
terraform destroy

# Type 'yes' when prompted
```

### Destroy the Bootstrap Infrastructure (Optional)

```bash
cd bootstrap/

# Remove the prevent_destroy lifecycle rule first,
# then empty the state bucket:
aws s3 rm s3://terraform-state-YOUR_ACCOUNT_ID --recursive

# Now destroy
terraform destroy
```

### Delete the IAM User

```bash
# List and delete access keys
aws iam list-access-keys --user-name github-actions-terraform
aws iam delete-access-key \
  --user-name github-actions-terraform \
  --access-key-id AKIA...

# Detach policies
aws iam detach-user-policy \
  --user-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam detach-user-policy \
  --user-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess

# Delete the user
aws iam delete-user --user-name github-actions-terraform
```

---

## Troubleshooting

### Common Issues & Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| `Error: NoSuchBucket` during `terraform init` | State bucket doesn't exist | Run the bootstrap in Step 1 first |
| `Error: AccessDenied` | IAM permissions insufficient | Check the IAM policies on `github-actions-terraform` user |
| `Error: state lock` | Previous run failed mid-apply | Run `terraform force-unlock <LOCK_ID>` |
| Yor workflow doesn't commit | No taggable resources found | Ensure `.tf` files have `tags` blocks in resources |
| `terraform fmt` fails | Code not formatted | Run `terraform fmt -recursive` locally before pushing |
| Plan shows `no changes` | Terraform files not in the path filter | Check `paths:` in `terraform.yml` matches your directory |

### Useful Debug Commands

```bash
# Check Terraform state
terraform state list
terraform state show aws_s3_bucket.app_assets

# Verify AWS credentials
aws sts get-caller-identity

# Check what Terraform would do without applying
terraform plan -detailed-exitcode

# View the state file in S3
aws s3 cp s3://terraform-state-YOUR_ACCOUNT_ID/demo-app/terraform.tfstate - | jq .

# Run Yor locally to preview tags
docker run --rm -v $(pwd):/data bridgecrew/yor tag -d /data/terraform
```

---

> **🎓 Learning Complete!** You now have a fully automated IaC pipeline with state management, PR-based review workflows, and automatic traceability tagging. The patterns here — remote state, PR-based plans, automated apply on merge — are the **same patterns used by production teams at scale**.

include "root" {
  path = find_in_parent_folders()
}

# ─────────────────────────────────────────────────────────────────────────────
# Dependencies
# ─────────────────────────────────────────────────────────────────────────────
# Needed for: (1) the Gateway VPC Endpoint's vpc_id, (2) ALL route tables
# (public AND private) so every EC2 regardless of subnet tier reaches this
# bucket without going through the internet. After the Phase 4 migration
# all EC2s are in public subnets — private_route_table_ids alone is no
# longer sufficient.
dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id                  = "vpc-mock12345"
    private_route_table_ids = ["rtb-mock1", "rtb-mock2"]
    public_route_table_ids  = ["rtb-mock3", "rtb-mock4"]
  }

  # Guard: mock outputs are ONLY valid for validate / plan.
  # Removing this allows `terragrunt apply` to silently wire the VPC
  # endpoint to a fake VPC ID and create a broken, unreachable endpoint.
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

locals {
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.yaml",     "${get_terragrunt_dir()}/empty.yaml"))
  account_vars = read_terragrunt_config(find_in_parent_folders("account.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.yaml",  "${get_terragrunt_dir()}/empty.yaml"))

  env        = local.env_vars.locals.environment
  account_id = local.account_vars.locals.aws_account_id
  region     = local.region_vars.locals.aws_region
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# Variables (injected by Terragrunt inputs block)
# ─────────────────────────────────────────────────────────────────────────────
variable "vpc_id"                  { type = string }
variable "private_route_table_ids" { type = list(string) }
variable "public_route_table_ids"  { type = list(string) }

# ─────────────────────────────────────────────────────────────────────────────
# Computed locals (values baked in at generate time by Terragrunt)
# ─────────────────────────────────────────────────────────────────────────────
locals {
  bucket_name = "shalotrack-${local.env}-gps-archive-${local.account_id}"

  common_tags = {
    Project     = "shalotrack"
    Environment = "${local.env}"
    ManagedBy   = "terragrunt"
    Component   = "gps-archive"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 BUCKET
# GPS trip archive. Written exactly once per closed trip by the C# API
# (IgnitionStatus TRUE→FALSE). Read back by the same API's Trip History
# merge after Postgres rows have been purged. No other process writes here.
# The lifecycle rules below are the only thing that removes objects — no app
# code or IAM DeleteObject grant is needed for normal operation.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "gps_archive" {
  bucket = local.bucket_name
  tags   = local.common_tags

  # Safety net: `terraform destroy` will fail hard unless you explicitly
  # remove this block or pass -target. Accept the inconvenience — an
  # accidental destroy of this bucket loses live customer trip history that
  # has already been purged from Postgres and cannot be recovered.
  lifecycle {
    prevent_destroy = true
  }
}

# ── Disable ACLs (AWS best practice since April 2023) ────────────────────────
# Object ownership is enforced to the bucket owner; all ACL grants are
# rejected. This must be applied before the public_access_block below.
resource "aws_s3_bucket_ownership_controls" "gps_archive" {
  bucket     = aws_s3_bucket.gps_archive.id
  depends_on = [aws_s3_bucket.gps_archive]

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ── Block all public access ───────────────────────────────────────────────────
# Customer vehicle location history has the same sensitivity as the Postgres
# data it came from. Public access is never valid here.
resource "aws_s3_bucket_public_access_block" "gps_archive" {
  bucket     = aws_s3_bucket.gps_archive.id
  depends_on = [aws_s3_bucket_ownership_controls.gps_archive]

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Encryption at rest ────────────────────────────────────────────────────────
# SSE-S3 (AES256) rather than SSE-KMS: avoids per-request KMS API call cost
# ($0.03 / 10 000 requests). Trip data is already access-controlled at the
# VPC-endpoint and bucket-policy layers; AES256 is sufficient for encryption
# at rest without KMS overhead.
resource "aws_s3_bucket_server_side_encryption_configuration" "gps_archive" {
  bucket = aws_s3_bucket.gps_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Versioning ────────────────────────────────────────────────────────────────
# Protects against a C# API bug that silently overwrites a trip archive with
# corrupt or empty bytes. With versioning on, the previous object is retained
# (for up to 30 days; see lifecycle rule below) giving enough time to detect
# the corruption and restore without a full Postgres restore. Because GPS
# history already purged from Postgres is unrecoverable by any other means,
# this is not optional.
resource "aws_s3_bucket_versioning" "gps_archive" {
  bucket = aws_s3_bucket.gps_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ── Lifecycle rules ───────────────────────────────────────────────────────────
resource "aws_s3_bucket_lifecycle_configuration" "gps_archive" {
  bucket     = aws_s3_bucket.gps_archive.id
  depends_on = [aws_s3_bucket_versioning.gps_archive]

  # ── Rule 1: Cost-optimise and expire current versions ────────────────────
  # Transition to Standard-IA at 30 days (≈ 50% storage cost saving).
  #
  # IMPORTANT — Standard-IA has a 128 KB minimum billable object size.
  # Before shipping: measure average per-trip archive size with:
  #   aws s3api list-objects-v2 \
  #     --bucket shalotrack-${local.env}-gps-archive-${local.account_id} \
  #     --prefix archive/ \
  #     --query 'Contents[].Size | avg(@)' \
  #     --output text
  # If a typical object is < 128 KB, set the transition status to "Disabled"
  # — IA will COST MORE than Standard for small objects.
  #
  # Combining expiration + noncurrent_version_expiration in one rule is
  # valid; the only AWS constraint is that expired_object_delete_marker
  # cannot share a rule with noncurrent_version_expiration (see Rule 2).
  rule {
    id     = "archive-trips-lifecycle"
    status = "Enabled"

    filter {
      prefix = "archive/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    # Purge noncurrent (overwritten) versions after 30 days.
    # Safety copies are useful for detecting corruption within a month;
    # after that they are dead weight billed at the same rate as live data.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # ── Rule 2: Clean up orphaned delete markers ─────────────────────────────
  # When a versioned object's current version expires, S3 replaces it with a
  # delete marker. Left uncleaned these markers accumulate in ListBucket
  # output and inflate the versioning metadata.
  # Must be its own rule: AWS rejects expired_object_delete_marker combined
  # with noncurrent_version_expiration in the same rule.
  rule {
    id     = "cleanup-delete-markers"
    status = "Enabled"

    filter {
      prefix = "archive/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  # ── Rule 3: Abort stuck multipart uploads ────────────────────────────────
  # A C# API process that crashes mid-upload leaves an incomplete MPU.
  # AWS bills for the partial parts indefinitely until the MPU is aborted.
  # 7 days is enough time to detect an upload failure in monitoring.
  # Applies to ALL prefixes so any future storage path is covered.
  rule {
    id     = "abort-incomplete-mpu"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Bucket policy ─────────────────────────────────────────────────────────────
# Two controls that IAM alone cannot provide:
#
#   DenyNonHTTPS
#     All S3 API calls must use TLS. A misconfigured SDK or tool that speaks
#     plain HTTP is rejected at the bucket boundary, regardless of IAM grants.
#
#   DenyNonVPCEndpointObjectAccess
#     Object-level reads and writes (GetObject, PutObject, DeleteObject,
#     ListBucket, etc.) MUST arrive through the VPC Gateway Endpoint.
#     Even if an EC2 instance role access key is leaked, the attacker cannot
#     download customer GPS data from outside the VPC — the bucket rejects
#     the request because aws:SourceVpce does not match.
#
#     Control-plane operations (PutBucketPolicy, PutBucketVersioning, etc.)
#     are intentionally left out of this Deny so that CI/CD (GitHub Actions
#     OIDC) can manage bucket configuration without a self-hosted VPC runner.
#     Control-plane ops don't touch customer data; only data-plane ops are
#     locked to the VPC endpoint.
resource "aws_s3_bucket_policy" "gps_archive" {
  bucket     = aws_s3_bucket.gps_archive.id
  depends_on = [aws_s3_bucket_public_access_block.gps_archive]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # ── 1. Enforce TLS for every S3 API call ─────────────────────────────
      {
        Sid       = "DenyNonHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.gps_archive.arn,
          "$${aws_s3_bucket.gps_archive.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },

      # ── 2. Lock data-plane access to the VPC Gateway Endpoint ────────────
      # Deny object reads/writes/lists that do NOT arrive through the
      # S3 VPC endpoint. Control-plane actions (PutBucketPolicy etc.) are
      # deliberately excluded so CI/CD can apply Terraform changes without
      # needing a self-hosted runner inside the VPC.
      {
        Sid       = "DenyNonVPCEndpointObjectAccess"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ]
        Resource = [
          aws_s3_bucket.gps_archive.arn,
          "$${aws_s3_bucket.gps_archive.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = aws_vpc_endpoint.s3.id
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC GATEWAY ENDPOINT FOR S3
# Free. Keeps all S3 traffic on the AWS backbone — no internet NAT, no
# egress charges. Attached to ALL route tables (public AND private) so every
# EC2 regardless of subnet tier uses the endpoint automatically.
#
# Before Phase 4: only private route tables were listed — this was sufficient
# while EC2s were in private subnets.
# After Phase 4: EC2s are in public subnets, so the public route tables must
# be included too. Without them, instances silently fall back to the public
# S3 endpoint, which bypasses the endpoint policy controls below and costs
# egress on every trip archive write.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    var.private_route_table_ids,
    var.public_route_table_ids
  )

  tags = merge(local.common_tags, {
    Name = "shalotrack-${local.env}-s3-gateway-endpoint"
  })
}

# ── VPC Endpoint policy ───────────────────────────────────────────────────────
# Restricts this endpoint so it can ONLY reach S3 buckets owned by THIS AWS
# account. Without this policy, the default is "allow all" — a compromised
# EC2 can use the endpoint as a free tunnel to exfiltrate customer GPS data
# to an attacker-controlled bucket in a different account. This is a real,
# documented AWS lateral-movement technique.
#
# The Terraform state bucket, the ECR S3 backing, and any other account-
# internal bucket remain fully reachable. Only cross-account access is blocked.
resource "aws_vpc_endpoint_policy" "s3" {
  vpc_endpoint_id = aws_vpc_endpoint.s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RestrictToThisAccount"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = "${local.account_id}"
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────
output "bucket_name" {
  value = aws_s3_bucket.gps_archive.id
}

output "bucket_arn" {
  value = aws_s3_bucket.gps_archive.arn
}

output "bucket_domain_name" {
  description = "Regional domain name — use this in SDK endpoint config, not the path-style URL."
  value       = aws_s3_bucket.gps_archive.bucket_regional_domain_name
}

output "vpc_endpoint_id" {
  description = "S3 Gateway Endpoint ID — reference in bucket policies using aws:SourceVpce."
  value       = aws_vpc_endpoint.s3.id
}
EOF
}

inputs = {
  vpc_id                  = dependency.vpc.outputs.vpc_id
  private_route_table_ids = dependency.vpc.outputs.private_route_table_ids
  public_route_table_ids  = dependency.vpc.outputs.public_route_table_ids
}

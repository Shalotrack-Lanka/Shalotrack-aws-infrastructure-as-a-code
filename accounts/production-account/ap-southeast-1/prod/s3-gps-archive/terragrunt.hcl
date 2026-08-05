include "root" {
  path = find_in_parent_folders()
}

# Needed for: (1) the Gateway VPC Endpoint's vpc_id, (2) the private route
# tables that endpoint attaches to so API/Gateway/Admin instances reach this
# bucket without going through the NAT Gateway.
dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id                  = "vpc-mock12345"
    private_route_table_ids = ["rtb-mock1", "rtb-mock2"]
  }
}

locals {
  # Same pattern the vpc/root modules already use — read env + account
  # straight from the shared yaml files instead of hardcoding.
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  account_vars = read_terragrunt_config(find_in_parent_folders("account.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.yaml", "${get_terragrunt_dir()}/empty.yaml"))

  env        = local.env_vars.locals.environment
  account_id = local.account_vars.locals.aws_account_id
  region     = local.region_vars.locals.aws_region
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id" { type = string }
variable "private_route_table_ids" { type = list(string) }

# GPS trip archive bucket. Written to exactly once per closed trip by the
# C# API (IgnitionStatus TRUE->FALSE), read back by the same API's Trip
# History fallback when Postgres no longer has the rows. Nothing else
# writes here, nothing ever calls DeleteObject on it -- the lifecycle rule
# below is the only thing that ever removes an object.
resource "aws_s3_bucket" "gps_archive" {
  bucket = "shalotrack-${local.env}-gps-archive-${local.account_id}"
}

# This bucket holds customer vehicle location history -- same sensitivity
# bar as the Postgres data it came from. Public access is never valid here.
resource "aws_s3_bucket_public_access_block" "gps_archive" {
  bucket = aws_s3_bucket.gps_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gps_archive" {
  bucket = aws_s3_bucket.gps_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Every object under archive/ expires automatically at 90 days. No app
# code, no cron, no IAM DeleteObject grant needed anywhere for this.
resource "aws_s3_bucket_lifecycle_configuration" "gps_archive" {
  bucket = aws_s3_bucket.gps_archive.id

  rule {
    id     = "expire-archived-trips"
    status = "Enabled"

    filter {
      prefix = "archive/"
    }

    expiration {
      days = 90
    }
  }
}

# Lets the private-subnet instances (API, Gateway, Admin, SRE all share one
# route table set) reach this bucket without routing through the NAT
# Gateway. Free -- pure win, no reason to skip it.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids
}

output "bucket_name" { value = aws_s3_bucket.gps_archive.id }
output "bucket_arn"  { value = aws_s3_bucket.gps_archive.arn }
EOF
}

inputs = {
  vpc_id                   = dependency.vpc.outputs.vpc_id
  private_route_table_ids  = dependency.vpc.outputs.private_route_table_ids
}

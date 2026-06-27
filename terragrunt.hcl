# Root Terragrunt configuration that generates providers and remote state backends
# inherits settings across all child directories

locals {
  # Automatically load organization, account, region, and environment variables
  org_vars     = read_terragrunt_config(find_in_parent_folders("org.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  account_vars = read_terragrunt_config(find_in_parent_folders("account.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.yaml", "${get_terragrunt_dir()}/empty.yaml"))

  # Extract clean local variables for inputs
  org_name     = local.org_vars.locals.org_name
  project_name = local.org_vars.locals.project_name
  account_id   = local.account_vars.locals.aws_account_id
  aws_region   = local.region_vars.locals.aws_region
  environment  = local.env_vars.locals.environment
}

# Generate AWS provider configuration dynamically for children
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region              = "${local.aws_region}"
  allowed_account_ids = ["${local.account_id}"]

  default_tags {
    tags = {
      Organization = "${local.org_name}"
      Project      = "${local.project_name}"
      Environment  = "${local.environment}"
      ManagedBy    = "Terragrunt"
    }
  }
}
EOF
}

# Remote state management via S3 bucket and DynamoDB lock table
remote_state {
  backend = "s3"
  config = {
    encrypt        = true
    bucket         = "terragrunt-state-${local.project_name}-${local.account_id}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    dynamodb_table = "terragrunt-locks-${local.project_name}"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# Forward global variables down as inputs to all modules automatically
inputs = {
  org_name     = local.org_name
  project_name = local.project_name
  account_id   = local.account_id
  aws_region   = local.aws_region
  environment  = local.environment
}
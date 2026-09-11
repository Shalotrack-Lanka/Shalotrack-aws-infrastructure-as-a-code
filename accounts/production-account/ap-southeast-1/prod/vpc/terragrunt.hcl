# Include the root terragrunt.hcl configurations (Providers, S3 State, Variables)
include "root" {
  path = find_in_parent_folders()
}

# Pull the official AWS VPC module from the Terraform Registry
terraform {
  source = "tfr:///terraform-aws-modules/vpc/aws?version=5.8.1"
}

# ---------------------------------------------------------------------------------------------------------------------
# LOCAL VARIABLES
# ---------------------------------------------------------------------------------------------------------------------
locals {
  # Automatically load the environment variables from the parent folders
  env_vars = read_terragrunt_config(find_in_parent_folders("env.yaml", "${get_terragrunt_dir()}/empty.yaml"))
  env      = local.env_vars.locals.environment
}

# ---------------------------------------------------------------------------------------------------------------------
# MODULE INPUTS
# ---------------------------------------------------------------------------------------------------------------------
inputs = {
  name = "shalotrack-${local.env}-vpc"
  cidr = "10.0.0.0/16"

  # High Availability: Spanning across two Availability Zones in Singapore
  azs             = ["ap-southeast-1a", "ap-southeast-1b"]

  # Public Subnets (For NLB, ALB, and EC2s after Phase 4 migration)
  # Matches your diagram: 10.0.1.0/24 (AZ-a) and 10.0.3.0/24 (AZ-b)
  public_subnets  = ["10.0.1.0/24", "10.0.3.0/24"]

  # Private Subnets (Kept in state — do not remove. Removing would destroy
  # the subnets and could cause a plan diff that recreates the VPC.)
  # Matches your diagram: 10.0.2.0/24 (AZ-a) and 10.0.4.0/24 (AZ-b)
  private_subnets = ["10.0.2.0/24", "10.0.4.0/24"]

  # PHASE 4: NAT Gateway disabled — all EC2s now use public subnets with
  # direct internet access controlled by Security Groups.
  # Saves ~$30/month. Do not re-enable without Nuwan Aloka approval.
  enable_nat_gateway     = false
  single_nat_gateway     = false
  one_nat_gateway_per_az = false

  # DNS Settings (Required for internal load balancing and Supabase resolution)
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tagging for cost tracking and identification
  public_subnet_tags = {
    Tier = "Public"
  }
  private_subnet_tags = {
    Tier = "Private"
  }
}

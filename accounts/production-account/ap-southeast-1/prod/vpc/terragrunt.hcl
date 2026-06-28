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
  
  # Public Subnets (For NLB, ALB, and NAT Gateway)
  # Matches your diagram: 10.0.1.0/24 (AZ-a) and adding 10.0.3.0/24 (AZ-b)
  public_subnets  = ["10.0.1.0/24", "10.0.3.0/24"]
  
  # Private Subnets (For Gateway ASG, API ASG, Admin EC2)
  # Matches your diagram: 10.0.2.0/24 (AZ-a) and adding 10.0.4.0/24 (AZ-b)
  private_subnets = ["10.0.2.0/24", "10.0.4.0/24"]

  # NAT Gateway Configuration
  enable_nat_gateway     = true
  single_nat_gateway     = true  # Keeps cost down: 1 Elastic IP for outbound traffic as per your design
  one_nat_gateway_per_az = false # Forces all private subnets to route through the single NAT

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
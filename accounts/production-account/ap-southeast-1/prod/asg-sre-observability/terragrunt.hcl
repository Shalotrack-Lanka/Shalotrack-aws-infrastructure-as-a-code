include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "tfr:///terraform-aws-modules/autoscaling/aws?version=8.0.0" 
}

dependency "vpc" {
  config_path = "../vpc"
}

dependency "security_groups" {
  config_path = "../security-groups"
}

dependency "iam" {
  config_path = "../iam-roles"
}

inputs = {
  name = "shalotrack-prod-sre-observability"

  # Enforce placement into Private Subnet B (10.0.4.0/24)
  # index [1] matches the second element of your private subnets configuration array
  vpc_zone_identifier = [dependency.vpc.outputs.private_subnets[1]]

  # Configuration for self-healing high-availability
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Compute specifications
  image_id      = "ami-0c20b881473657469" # Standard Ubuntu 24.04 LTS for ap-southeast-1
  instance_type = "t3.small"

  security_groups = [dependency.security_groups.outputs.sre_security_group_id]
  iam_instance_profile_arn = dependency.iam.outputs.ec2_instance_profile_arn

  user_data = filebase64("${get_terragrunt_dir()}/../scripts/sre-user-data.sh")

  block_device_mappings = [
    {
      device_name = "/dev/sda1"
      ebs = {
        volume_size           = 30 # Expanded allocation to store persistent metrics/logs locally
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = false # Protects telemetry directories during scaling refreshes
      }
    }
  ]

  tags = {
    Environment = "production"
    Project     = "Shalotrack-SRE"
    ManagedBy   = "Terragrunt"
  }
}
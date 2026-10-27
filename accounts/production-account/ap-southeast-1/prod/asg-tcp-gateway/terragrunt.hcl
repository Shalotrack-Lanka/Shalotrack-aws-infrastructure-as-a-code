include "root" {
  path = find_in_parent_folders()
}

dependency "vpc" { config_path = "../vpc" }
dependency "sg"  { config_path = "../security-groups" }
dependency "iam" { config_path = "../iam-roles" }
dependency "nlb" { config_path = "../nlb-gateway" }
dependency "ecr" { config_path = "../ecr-repositories" }

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "public_subnets" { type = list(string) }
variable "gateway_sg"     { type = string }
variable "iam_profile"    { type = string }
variable "tg_arn"         { type = string }
variable "ecr_url"        { type = string }
# NEW (2026-10-27) -- shalotrack.internal private zone, manually created,
# not Terraform-owned. See gateway-user-data.sh for the self-registration
# call that uses this.
variable "hosted_zone_id" { type = string }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_launch_template" "gateway" {
  name_prefix          = "shalotrack-gateway-"
  image_id             = data.aws_ami.amazon_linux.id
  instance_type        = "t3.micro"
  iam_instance_profile { name = var.iam_profile }

  # PHASE 4: associate_public_ip_address = true moves this EC2 to public subnet.
  # vpc_security_group_ids removed — security groups are now set inside
  # network_interfaces when associate_public_ip_address is used.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.gateway_sg]
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${replace(get_terragrunt_dir(), "\\", "/")}/../scripts/gateway-user-data.sh", {
    ecr_url        = var.ecr_url
    hosted_zone_id = var.hosted_zone_id
  }))
}

resource "aws_autoscaling_group" "gateway" {
  name                = "shalotrack-gateway-asg"
  vpc_zone_identifier = var.public_subnets
  target_group_arns   = [var.tg_arn]
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.gateway.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Gateway-shalotrack"
    propagate_at_launch = true
  }
}
EOF
}

inputs = {
  public_subnets = dependency.vpc.outputs.public_subnets
  gateway_sg     = dependency.sg.outputs.gateway_sg_id
  # CHANGED (2026-10-27): was dependency.iam.outputs.instance_profile_name
  # (the role shared with admin/api/fleet) -- gateway now gets its own
  # dedicated role so only it can write to gateway.shalotrack.internal.
  iam_profile    = dependency.iam.outputs.gateway_instance_profile_name
  tg_arn         = dependency.nlb.outputs.gateway_tg_arn
  ecr_url        = dependency.ecr.outputs.gateway_repo_url
  # NEW (2026-10-27): shalotrack.internal private hosted zone ID, hardcoded
  # because the zone is manually created, not a Terraform resource.
  hosted_zone_id = "Z06675171G0TY639DCHZN"
}
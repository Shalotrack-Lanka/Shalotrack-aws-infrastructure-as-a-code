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
variable "private_subnets" { type = list(string) }
variable "gateway_sg" { type = string }
variable "iam_profile" { type = string }
variable "tg_arn" { type = string }
variable "ecr_url" { type = string }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter { 
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"] 
  }
}

resource "aws_launch_template" "gateway" {
  name_prefix   = "shalotrack-gateway-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.gateway_sg]

  # Reads the clean shell script from the scripts folder and renders variables
  user_data = base64encode(templatefile("${get_terragrunt_dir()}/../scripts/gateway-user-data.sh", {
    ecr_url = var.ecr_url
  }))
}

resource "aws_autoscaling_group" "gateway" {
  name                = "shalotrack-gateway-asg"
  vpc_zone_identifier = var.private_subnets
  target_group_arns   = [var.tg_arn]
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  launch_template {
    id      = aws_launch_template.gateway.id
    version = "$Latest"
  }
}
EOF
}

inputs = {
  private_subnets = dependency.vpc.outputs.private_subnets
  gateway_sg      = dependency.sg.outputs.gateway_sg_id
  iam_profile     = dependency.iam.outputs.instance_profile_name
  tg_arn          = dependency.nlb.outputs.gateway_tg_arn
  ecr_url         = dependency.ecr.outputs.gateway_repo_url
}
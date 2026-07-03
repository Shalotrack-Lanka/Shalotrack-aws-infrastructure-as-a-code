include "root" {
  path = find_in_parent_folders()
}

dependency "vpc" { config_path = "../vpc" }
dependency "sg"  { config_path = "../security-groups" }
dependency "iam" { config_path = "../iam-roles" }
dependency "alb" { config_path = "../alb-shared" }
dependency "ecr" { config_path = "../ecr-repositories" }

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "private_subnets" { type = list(string) }
variable "web_sg" { type = string }
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

resource "aws_instance" "admin" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = "t3.micro"
  subnet_id            = var.private_subnets[0]
  vpc_security_group_ids = [var.web_sg]
  iam_instance_profile = var.iam_profile

  # Absolute path fix via get_terragrunt_dir()
  user_data = base64encode(templatefile("${get_terragrunt_dir()}/../scripts/admin-user-data.sh", {
    ecr_url = var.ecr_url
  }))

  tags = { Name = "shalotrack-admin-portal" }
}

resource "aws_lb_target_group_attachment" "admin_attach" {
  target_group_arn = var.tg_arn
  target_id        = aws_instance.admin.id
  port             = 80
}
EOF
}

inputs = {
  private_subnets = dependency.vpc.outputs.private_subnets
  web_sg          = dependency.sg.outputs.web_sg_id
  iam_profile     = dependency.iam.outputs.instance_profile_name
  tg_arn          = dependency.alb.outputs.admin_tg_arn
  ecr_url         = dependency.ecr.outputs.admin_repo_url
}
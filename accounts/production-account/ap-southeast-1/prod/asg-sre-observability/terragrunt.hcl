include "root" {
  path = find_in_parent_folders()
}

dependency "vpc" { config_path = "../vpc" }
dependency "sg"  { config_path = "../security-groups" }
dependency "iam" { config_path = "../iam-roles" }
dependency "alb" { config_path = "../alb-shared" }

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "private_subnets" { type = list(string) }
variable "sre_sg" { type = string }
variable "iam_profile" { type = string }
variable "tg_arn" { type = string }

# Dynamically fetch the latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter { 
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"] 
  }
}

# Look up the AZ dynamically from the subnet we're actually pinned to,
# so the EBS volume always lands in the same AZ as the instance
data "aws_subnet" "sre_subnet" {
  id = var.private_subnets[1]
}

# Persistent data volume — created once, survives ASG instance replacement.
# Holds Grafana/Prometheus/Loki/Tempo data outside the root disk.
resource "aws_ebs_volume" "sre_data" {
  availability_zone = data.aws_subnet.sre_subnet.availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "shalotrack-sre-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_launch_template" "sre" {
  name_prefix   = "shalotrack-sre-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.small"
  iam_instance_profile { name = var.iam_profile }
  vpc_security_group_ids = [var.sre_sg]

  user_data = base64encode(templatefile("${get_terragrunt_dir()}/../scripts/sre-user-data.sh", {
    volume_id = aws_ebs_volume.sre_data.id
  }))
  
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
      encrypted   = true
    }
  }
}

resource "aws_autoscaling_group" "sre" {
  name                = "shalotrack-sre-asg"
  # Using index [1] restricts this strictly to the 10.0.4.0/24 subnet (AZ B)
  vpc_zone_identifier = [var.private_subnets[1]]
  target_group_arns   = [var.tg_arn]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  
  launch_template {
    id      = aws_launch_template.sre.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "SRE-Observability"
    propagate_at_launch = true
  }
}

output "sre_data_volume_id" { value = aws_ebs_volume.sre_data.id }
EOF
}

inputs = {
  private_subnets = dependency.vpc.outputs.private_subnets
  sre_sg          = dependency.sg.outputs.sre_security_group_id
  iam_profile     = dependency.iam.outputs.instance_profile_name
  tg_arn          = dependency.alb.outputs.sre_tg_arn
}
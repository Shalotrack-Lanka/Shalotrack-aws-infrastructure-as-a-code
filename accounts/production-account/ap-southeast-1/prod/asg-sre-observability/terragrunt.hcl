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
variable "public_subnets" { type = list(string) }
variable "sre_sg"         { type = string }
variable "iam_profile"    { type = string }
variable "tg_arn"         { type = string }
variable "vpc_id"         { type = string }

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
  id = var.public_subnets[1]
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

# Private DNS zone for internal service discovery — lets apps target a stable
# hostname (otel.shalotrack.internal) instead of an IP that changes on instance replacement.
resource "aws_route53_zone" "internal" {
  name          = "shalotrack.internal"
  force_destroy = false

  vpc {
    vpc_id = var.vpc_id
  }

  comment = "Private zone for internal service discovery (OTel endpoint, etc.)"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_launch_template" "sre" {
  name_prefix          = "shalotrack-sre-"
  image_id             = data.aws_ami.amazon_linux.id
  instance_type        = "t3.micro"
  iam_instance_profile { name = var.iam_profile }

  # PHASE 4: associate_public_ip_address = true moves this EC2 to public subnet.
  # vpc_security_group_ids removed — security groups are now set inside
  # network_interfaces when associate_public_ip_address is used.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.sre_sg]
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${get_terragrunt_dir()}/../scripts/sre-user-data.sh", {
    volume_id = aws_ebs_volume.sre_data.id
    zone_id   = aws_route53_zone.internal.zone_id
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
  # Using index [1] restricts this strictly to the AZ-b public subnet (10.0.3.0/24)
  # keeping it in the same AZ as the persistent EBS volume
  vpc_zone_identifier = [var.public_subnets[1]]
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
output "internal_zone_id"   { value = aws_route53_zone.internal.zone_id }
EOF
}

inputs = {
  public_subnets = dependency.vpc.outputs.public_subnets
  sre_sg         = dependency.sg.outputs.sre_security_group_id
  iam_profile    = dependency.iam.outputs.instance_profile_name
  tg_arn         = dependency.alb.outputs.sre_tg_arn
  vpc_id         = dependency.vpc.outputs.vpc_id
}

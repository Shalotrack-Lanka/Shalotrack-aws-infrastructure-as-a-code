include "root" {
  path = find_in_parent_folders()
}

# Pull data from VPC phase
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id         = "vpc-mock123"
    public_subnets = ["subnet-mock1", "subnet-mock2"]
  }
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }

# 1. Create the high-throughput TCP Network Load Balancer
resource "aws_lb" "gateway_nlb" {
  name               = "shalotrack-gateway-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnets
}

# 2. Create the Target Group (The "bucket" for your Python EC2 instances)
resource "aws_lb_target_group" "gateway_tg" {
  name        = "shalotrack-gateway-tg"
  port        = 8000
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # CRITICAL SRE FIX: 5-minute connection draining to prevent data gaps
  deregistration_delay = 300

  health_check {
    protocol = "TCP"
    port     = "8000"
    interval = 30
  }
}

# 3. Listen on Port 8000 and forward to the Target Group
resource "aws_lb_listener" "gateway_tcp" {
  load_balancer_arn = aws_lb.gateway_nlb.arn
  port              = 8000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway_tg.arn
  }
}

output "nlb_dns_name" { value = aws_lb.gateway_nlb.dns_name }
output "gateway_tg_arn" { value = aws_lb_target_group.gateway_tg.arn }
EOF
}

inputs = {
  vpc_id         = dependency.vpc.outputs.vpc_id
  public_subnets = dependency.vpc.outputs.public_subnets
}
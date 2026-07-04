include "root" {
  path = find_in_parent_folders()
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id         = "vpc-mock123"
    public_subnets = ["subnet-mock1", "subnet-mock2"]
  }
}

dependency "sg" {
  config_path = "../security-groups"
  mock_outputs = {
    lb_sg_id = "sg-mock123"
  }
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }
variable "lb_sg_id" { type = string }

# 1. Create the Application Load Balancer
resource "aws_lb" "shared_alb" {
  name               = "shalotrack-shared-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.lb_sg_id]
  subnets            = var.public_subnets
}

# 2. Target Group for C# REST API
resource "aws_lb_target_group" "api_tg" {
  name        = "shalotrack-api-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/api/Customer"
    port                = "80"
    protocol            = "HTTP"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-499" 
  }
}

# 3. Target Group for Laravel Admin
resource "aws_lb_target_group" "admin_tg" {
  name        = "shalotrack-admin-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path = "/"
    port = "80"
  }
}

# 4. Standard HTTP Listener
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.shared_alb.arn
  port              = 80
  protocol          = "HTTP"

  # Default action sends unmapped traffic to the Laravel Admin
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin_tg.arn
  }
}

# 5. Advanced Routing Rule: Send 'api.*' domains to C#
resource "aws_lb_listener_rule" "api_rule" {
  listener_arn = aws_lb_listener.http_listener.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_tg.arn
  }

  condition {
    host_header {
      values = ["api.*"] 
    }
  }
}

output "alb_dns_name" { value = aws_lb.shared_alb.dns_name }
output "api_tg_arn" { value = aws_lb_target_group.api_tg.arn }
output "admin_tg_arn" { value = aws_lb_target_group.admin_tg.arn }
EOF
}

inputs = {
  vpc_id         = dependency.vpc.outputs.vpc_id
  public_subnets = dependency.vpc.outputs.public_subnets
  lb_sg_id       = dependency.sg.outputs.lb_sg_id
}
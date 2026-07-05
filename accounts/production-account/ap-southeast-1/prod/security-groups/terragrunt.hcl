include "root" {
  path = find_in_parent_folders()
}

# Pull the VPC ID from the previously deployed Phase 1
dependency "vpc" {
  config_path = "../vpc"
  
  # Mock outputs ensure 'terragrunt plan' works even if VPC isn't fully applied yet
  mock_outputs = {
    vpc_id = "vpc-mock12345"
  }
}

# Generate raw Terraform resources for the exact firewall rules
generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id" {
  type = string
}

# 1. External Load Balancer SG (Allows internet traffic in)
resource "aws_security_group" "load_balancers" {
  name        = "shalotrack-lb-sg"
  description = "Allow inbound TCP 8000 for GPS and 443 for HTTPS"
  vpc_id      = var.vpc_id

  ingress {
    description = "GPS GT06 Protocol"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS Web/API Traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Internal Gateway ASG SG (Only accepts traffic from the Load Balancer)
resource "aws_security_group" "gateway_asg" {
  name        = "shalotrack-gateway-sg"
  description = "Allow TCP 8000 only from NLB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "TCP 8000 from LB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Internal API & Admin SG (Only accepts traffic from the Load Balancer)
resource "aws_security_group" "web_asg" {
  name        = "shalotrack-web-sg"
  description = "Allow HTTP/HTTPS only from ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Traffic from LB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancers.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "lb_sg_id" { value = aws_security_group.load_balancers.id }
output "gateway_sg_id" { value = aws_security_group.gateway_asg.id }
output "web_sg_id" { value = aws_security_group.web_asg.id }
EOF
}

inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id
}
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
    description = "HTTP Traffic from Cloudflare"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
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
    cidr_blocks     = ["0.0.0.0/0"]
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

# 4. SRE Observability Instance SG (Internal Telemetry Isolation Engine)
resource "aws_security_group" "sre_observability" {
  name        = "shalotrack-sre-sg"
  description = "Isolate internal telemetry stack data processing points"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow OpenTelemetry gRPC from VPC internal nodes"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "Allow OpenTelemetry HTTP from VPC internal nodes"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "Allow Loki log pushes from internal services"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "Allow Prometheus metrics scraping internally"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "Allow outbound out via NAT gateway to Cloudflare endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "lb_sg_id" { value = aws_security_group.load_balancers.id }
output "gateway_sg_id" { value = aws_security_group.gateway_asg.id }
output "web_sg_id" { value = aws_security_group.web_asg.id }
output "sre_security_group_id" { value = aws_security_group.sre_observability.id }
EOF
}

inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id
}
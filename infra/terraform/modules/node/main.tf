data "aws_caller_identity" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ---------- Red: VPC propia con una subnet pública ----------
# Sin NAT Gateway (~$32/mes): la EC2 sale a internet por el Internet Gateway con su IP pública y el
# Security Group bloquea toda la entrada que no esté en ingress_rules.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # x.x.1.0/24
  availability_zone_id    = var.availability_zone_id
  map_public_ip_on_launch = true

  tags = { Name = "discordia-${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "discordia-${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Security Group ----------
# Reglas como recursos sueltos (no inline): se pueden sumar desde afuera sin reemplazar el SG.

resource "aws_security_group" "node" {
  name        = "discordia-${var.name}"
  description = "Nodo ${var.name} de Discordia"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = {
    for rule in var.ingress_rules :
    "${rule.protocol}-${rule.from_port}-${rule.to_port}-${rule.cidr_ipv4}" => rule
  }

  security_group_id = aws_security_group.node.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Salida a internet (imagenes, Auth0, Atlas) y a los otros nodos"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------- Acceso de administración por SSM (sin puerto 22 ni claves SSH) ----------

resource "aws_iam_role" "ssm" {
  name = "discordia-${var.name}-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "discordia-${var.name}-ssm"
  role = aws_iam_role.ssm.name
}

# ---------- EC2 ----------

resource "aws_instance" "node" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = var.private_ip
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    node_name = var.name
  })

  # "standard": si se agotan los créditos de CPU la instancia se frena en vez de cobrar el excedente
  # (en "unlimited", el default de t3, ese excedente se cobra aparte).
  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  # IMDSv2 obligatorio: evita que un SSRF en algún servicio lea las credenciales del rol de la instancia
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Una AMI nueva o un cambio en el script de arranque no deben recrear la máquina (y perder sus datos)
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_eip" "node" {
  count  = var.elastic_ip ? 1 : 0
  domain = "vpc"

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_eip_association" "node" {
  count         = var.elastic_ip ? 1 : 0
  instance_id   = aws_instance.node.id
  allocation_id = aws_eip.node[0].id
}

# ---------- Alerta de gasto ----------
# Mide el costo neto (descontados los créditos): avisa apenas la cuenta empieza a gastar plata real.

resource "aws_budgets_budget" "net_spend" {
  name         = "discordia-${var.name}-gasto-real"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

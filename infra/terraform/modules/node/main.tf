# Una EC2 de Discordia: instancia, rol de SSM e IP pública fija opcional.
# La red (VPC, subnets) y los Security Groups se definen en la raíz.
# Los nombres de los recursos (aws_eip.node, aws_iam_role.ssm, ...) no se cambian: son las direcciones
# en el estado de Terraform y cambiarlas recrearía la Elastic IP (y cambiaría la IP pública).

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
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
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [var.security_group_id]
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
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = var.imds_hop_limit
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

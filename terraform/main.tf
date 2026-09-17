provider "aws" {
  region = var.aws_region
}

# 1. Buscar la última imagen (AMI) de Amazon Linux 2023
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# 2. Crear el Security Group
resource "aws_security_group" "instance_sg" {
  name        = "discordia-instance-sg"
  description = "Permitir trafico SSH, HTTP y puertos de la aplicacion"

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # HTTP (WebApp si se mapea al 80)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # WebApp (Vite dev server)
  ingress {
    from_port   = 5173
    to_port     = 5173
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Auth Service
  ingress {
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Roles Service
  ingress {
    from_port   = 8002
    to_port     = 8002
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Payments Service
  ingress {
    from_port   = 8003
    to_port     = 8003
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Chat Service
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Notification Service
  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Voice Service
  ingress {
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = [var.ssh_and_web_location]
  }

  # Permitir todo el trafico de salida para que la instancia pueda bajar paquetes/internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Roles de IAM (Session Manager)
resource "aws_iam_role" "session_manager_role" {
  name = "discordia-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.session_manager_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "session_manager_profile" {
  name = "discordia-ssm-profile"
  role = aws_iam_role.session_manager_role.name
}

# 4. Crear la Instancia EC2
resource "aws_instance" "app_server" {
  ami                  = data.aws_ami.amazon_linux_2023.id
  

  instance_type        = var.instance_type
  
  iam_instance_profile = aws_iam_instance_profile.session_manager_profile.name
  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  key_name             = var.key_name

  # User Data: Script que corre cuando la máquina enciende por primera vez.
  # Instala Docker y Docker Compose automáticamente.
  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y docker git
              systemctl enable docker
              systemctl start docker
              usermod -aG docker ec2-user
              
              # Instalar Docker Compose
              curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              EOF

  tags = {
    Name = "Discordia-Orchestrator-Server"
  }
}


# Una VPC para todo: las tres EC2 en una subnet pública y el RDS en dos subnets privadas.
#
# Sin NAT Gateway (~$32/mes): las EC2 salen a internet por el Internet Gateway con su IP pública y los
# Security Groups bloquean toda la entrada que no esté en security.tf. Las subnets de datos no tienen
# ruta a internet: el RDS solo es alcanzable desde adentro de la VPC.

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # necesario para que el endpoint del RDS resuelva a su IP privada

  tags = { Name = "discordia" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "discordia" }
}

# ---------- Subnet pública: las tres EC2 ----------

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidr
  availability_zone_id    = var.availability_zone_id
  map_public_ip_on_launch = true

  tags = { Name = "discordia-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "discordia-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Subnets de datos: RDS ----------
# Usan la tabla de rutas por defecto de la VPC (solo tráfico interno, sin salida a internet).

resource "aws_subnet" "data_a" {
  vpc_id               = aws_vpc.main.id
  cidr_block           = local.data_a_cidr
  availability_zone_id = var.availability_zone_id

  tags = { Name = "discordia-data-a" }
}

resource "aws_subnet" "data_b" {
  vpc_id               = aws_vpc.main.id
  cidr_block           = local.data_b_cidr
  availability_zone_id = var.data_secondary_az_id

  tags = { Name = "discordia-data-b" }
}

resource "aws_db_subnet_group" "data" {
  name        = "discordia-data"
  description = "Subnets privadas del RDS de Discordia"
  subnet_ids  = [aws_subnet.data_a.id, aws_subnet.data_b.id]

  tags = { Name = "discordia-data" }
}

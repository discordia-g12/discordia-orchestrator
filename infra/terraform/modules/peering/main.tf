# VPC peering entre dos cuentas de AWS: el tráfico entre nodos va por la red privada de AWS
# (sin pasar por internet). El peering es gratis; entre nodos en la misma AZ física tampoco se paga
# transferencia. No es transitivo: tres nodos necesitan tres conexiones.

resource "aws_vpc_peering_connection" "this" {
  provider = aws.requester

  vpc_id        = var.requester.vpc_id
  peer_vpc_id   = var.accepter.vpc_id
  peer_owner_id = var.accepter.account_id
  peer_region   = var.region

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.accepter

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = { Name = "discordia-${var.name}" }
}

resource "aws_route" "requester_to_accepter" {
  provider = aws.requester

  route_table_id            = var.requester.route_table_id
  destination_cidr_block    = var.accepter.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

resource "aws_route" "accepter_to_requester" {
  provider = aws.accepter

  route_table_id            = var.accepter.route_table_id
  destination_cidr_block    = var.requester.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

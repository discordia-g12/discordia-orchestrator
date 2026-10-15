output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "route_table_id" {
  value = aws_route_table.public.id
}

output "instance_id" {
  value = aws_instance.node.id
}

output "private_ip" {
  value = aws_instance.node.private_ip
}

output "public_ip" {
  description = "Elastic IP si tiene; si no, la IP pública automática (cambia si la instancia se reinicia apagada)"
  value       = var.elastic_ip ? aws_eip.node[0].public_ip : aws_instance.node.public_ip
}

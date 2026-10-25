output "instance_id" {
  value = aws_instance.node.id
}

output "private_ip" {
  value = aws_instance.node.private_ip
}

output "public_ip" {
  description = "Elastic IP si tiene; si no, la IP pública automática (cambia si la instancia se apaga y prende)"
  value       = var.elastic_ip ? aws_eip.node[0].public_ip : aws_instance.node.public_ip
}

output "role_name" {
  description = "Rol IAM de la instancia: la raíz le agrega permisos propios del nodo (ej. S3 en edge)"
  value       = aws_iam_role.ssm.name
}

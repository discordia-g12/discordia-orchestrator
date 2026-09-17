output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.app_server.id
}

output "availability_zone" {
  description = "Zona de disponibilidad de la instancia"
  value       = aws_instance.app_server.availability_zone
}

output "public_dns" {
  description = "DNS Público de la instancia"
  value       = aws_instance.app_server.public_dns
}

output "public_ip" {
  description = "IP Pública de la instancia"
  value       = aws_instance.app_server.public_ip
}


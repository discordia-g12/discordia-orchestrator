output "nodes" {
  description = "IPs de cada nodo: las privadas van en los nodes.env (EDGE_HOST, REALTIME_HOST, INFRA_HOST)"
  value = {
    edge     = { private_ip = module.edge.private_ip, public_ip = module.edge.public_ip, instance_id = module.edge.instance_id }
    realtime = { private_ip = module.realtime.private_ip, public_ip = module.realtime.public_ip, instance_id = module.realtime.instance_id }
    infra    = { private_ip = module.infra.private_ip, public_ip = module.infra.public_ip, instance_id = module.infra.instance_id }
  }
}

output "ssm_connect" {
  description = "Cómo entrar a cada nodo (sin SSH)"
  value = {
    edge     = "aws ssm start-session --profile ${var.aws_profile} --target ${module.edge.instance_id}"
    realtime = "aws ssm start-session --profile ${var.aws_profile} --target ${module.realtime.instance_id}"
    infra    = "aws ssm start-session --profile ${var.aws_profile} --target ${module.infra.instance_id}"
  }
}

output "rds_endpoint" {
  description = "DB_HOST de los nodes.env"
  value       = data.aws_db_instance.main.address
}

output "rds_move_command" {
  description = "Comando para mover el RDS a esta VPC (una sola vez, ver README)"
  value       = "aws rds modify-db-instance --profile ${var.aws_profile} --db-instance-identifier ${var.rds_identifier} --db-subnet-group-name ${aws_db_subnet_group.data.name} --vpc-security-group-ids ${aws_security_group.rds.id} --apply-immediately"
}

output "cloudflare_trusted_ips" {
  description = "Rangos IPv4 de Cloudflare para KONG_TRUSTED_IPS (deploy/gateway.env)"
  value       = join(",", local.cloudflare_ipv4)
}

output "media_bucket" {
  description = "S3_BUCKET y S3_PUBLIC_BASE_URL de Auth y Server-Roles"
  value = {
    name            = aws_s3_bucket.media.bucket
    public_base_url = "https://${aws_s3_bucket.media.bucket_regional_domain_name}"
  }
}

output "media_access_key_commands" {
  description = "Crear las access keys de cada servicio (una vez, o para rotarlas). Van al nodes.env del nodo donde corra cada servicio"
  value = {
    for service, user in aws_iam_user.media :
    service => "aws iam create-access-key --profile ${var.aws_profile} --user-name ${user.name}"
  }
}

output "cd_role_arn" {
  description = "Rol que asume el workflow de deploy (fijo en .github/workflows/deploy.yml)"
  value       = aws_iam_role.cd.arn
}

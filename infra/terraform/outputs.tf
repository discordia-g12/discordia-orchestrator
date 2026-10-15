output "nodes" {
  description = "IPs de cada nodo: las privadas van en los .env y en el kong.yml de producción"
  value = {
    edge     = { private_ip = module.edge.private_ip, public_ip = module.edge.public_ip, instance_id = module.edge.instance_id }
    realtime = { private_ip = module.realtime.private_ip, public_ip = module.realtime.public_ip, instance_id = module.realtime.instance_id }
    infra    = { private_ip = module.infra.private_ip, public_ip = module.infra.public_ip, instance_id = module.infra.instance_id }
  }
}

output "ssm_connect" {
  description = "Cómo entrar a cada nodo (sin SSH): aws ssm start-session con el profile de su cuenta"
  value = {
    edge     = "aws ssm start-session --profile ${var.aws_profiles.edge} --target ${module.edge.instance_id}"
    realtime = "aws ssm start-session --profile ${var.aws_profiles.realtime} --target ${module.realtime.instance_id}"
    infra    = "aws ssm start-session --profile ${var.aws_profiles.infra} --target ${module.infra.instance_id}"
  }
}

output "cloudflare_trusted_ips" {
  description = "Rangos IPv4 de Cloudflare para KONG_TRUSTED_IPS (deploy/edge/gateway.env)"
  value       = join(",", local.cloudflare_ipv4)
}

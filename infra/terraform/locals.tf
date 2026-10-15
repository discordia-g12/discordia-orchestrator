locals {
  common_tags = {
    Project   = "discordia"
    ManagedBy = "terraform"
  }

  # Rangos sin superposición: requisito del VPC peering entre las tres cuentas
  cidrs = {
    edge     = "10.10.0.0/16"
    realtime = "10.20.0.0/16"
    infra    = "10.30.0.0/16"
  }

  # IPs privadas fijas: son las que van en los .env de cada servicio y en el kong.yml de producción
  private_ips = {
    edge     = "10.10.1.10"
    realtime = "10.20.1.10"
    infra    = "10.30.1.10"
  }

  # Solo Cloudflare puede llegarle a Kong (el origen no queda expuesto a internet)
  cloudflare_ipv4 = data.cloudflare_ip_ranges.current.ipv4_cidr_blocks
}

data "cloudflare_ip_ranges" "current" {}

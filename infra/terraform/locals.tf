locals {
  common_tags = {
    Project   = "discordia"
    ManagedBy = "terraform"
  }

  nodes = ["edge", "realtime", "infra"]

  vpc_cidr       = "10.0.0.0/16"
  public_cidr    = "10.0.1.0/24"  # las 3 EC2
  data_a_cidr    = "10.0.64.0/24" # RDS (sin salida a internet)
  data_b_cidr    = "10.0.66.0/24" # RDS: su zona actual (us-east-1f) y segunda zona del grupo

  # IPs privadas fijas: van en los nodes.env (EDGE_HOST, REALTIME_HOST, INFRA_HOST)
  private_ips = {
    edge     = "10.0.1.10"
    realtime = "10.0.1.20"
    infra    = "10.0.1.30"
  }

  # Bucket de imágenes (storage.tf): qué servicio escribe en qué prefijo. Todos los prefijos son públicos.
  media_writers = {
    auth         = "avatars"
    server-roles = "server-icons"
  }
  media_prefixes = values(local.media_writers)

  # Solo Cloudflare puede llegarle a Kong (el origen no queda expuesto a internet)
  cloudflare_ipv4 = data.cloudflare_ip_ranges.current.ipv4_cidr_blocks
}

data "cloudflare_ip_ranges" "current" {}

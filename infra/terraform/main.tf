# Discordia en tres nodos, uno por cuenta de AWS:
#   edge     → Kong, Auth (+ worker), Server-Roles (+ worker), su Postgres y el Redis de Kong
#   realtime → Chat, Voice, LiveKit, Notification, su Postgres y los Redis de chat y voz
#   infra    → RabbitMQ, Payments (+ Postgres), Prometheus y Grafana
#   los tres → Node Exporter y cAdvisor (métricas que lee el Prometheus de infra)
# Afuera: Cloudflare (DNS + proxy), Vercel (SPA), MongoDB Atlas M0 (historial del chat).

# ---------- Nodo 1: edge ----------
module "edge" {
  source    = "./modules/node"
  providers = { aws = aws.edge }

  name                 = "edge"
  vpc_cidr             = local.cidrs.edge
  private_ip           = local.private_ips.edge
  availability_zone_id = var.availability_zone_id
  instance_type        = var.instance_type
  root_volume_gb       = var.root_volume_gb
  elastic_ip           = true # api.discordia.lol apunta acá
  budget_alert_email   = var.budget_alert_email

  ingress_rules = concat(
    # Kong con TLS (Cloudflare Origin Certificate), solo desde Cloudflare
    [for cidr in local.cloudflare_ipv4 : {
      description = "Kong HTTPS desde Cloudflare"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_ipv4   = cidr
    }],
    [
      {
        # Temporal: Chat y Voice consultan can-send / can-connect hasta tener la foto de permisos por eventos
        description = "Server-Roles internal desde realtime"
        protocol    = "tcp"
        from_port   = 8002
        to_port     = 8002
        cidr_ipv4   = local.cidrs.realtime
      },
      {
        description = "Node Exporter para Prometheus"
        protocol    = "tcp"
        from_port   = 9100
        to_port     = 9100
        cidr_ipv4   = local.cidrs.infra
      },
      {
        description = "cAdvisor para Prometheus"
        protocol    = "tcp"
        from_port   = 9180
        to_port     = 9180
        cidr_ipv4   = local.cidrs.infra
      },
    ]
  )
}

# ---------- Nodo 2: realtime ----------
module "realtime" {
  source    = "./modules/node"
  providers = { aws = aws.realtime }

  name                 = "realtime"
  vpc_cidr             = local.cidrs.realtime
  private_ip           = local.private_ips.realtime
  availability_zone_id = var.availability_zone_id
  instance_type        = var.instance_type
  root_volume_gb       = var.root_volume_gb
  elastic_ip           = true # NODE_IP de LiveKit y allowlist de MongoDB Atlas
  budget_alert_email   = var.budget_alert_email

  ingress_rules = [
    { description = "Chat-Engine desde Kong", protocol = "tcp", from_port = 3000, to_port = 3000, cidr_ipv4 = local.cidrs.edge },
    { description = "Voice-Signaling desde Kong", protocol = "tcp", from_port = 8082, to_port = 8082, cidr_ipv4 = local.cidrs.edge },
    { description = "Notification desde Kong", protocol = "tcp", from_port = 3001, to_port = 3001, cidr_ipv4 = local.cidrs.edge },
    { description = "Senalizacion de LiveKit desde Kong", protocol = "tcp", from_port = 7880, to_port = 7880, cidr_ipv4 = local.cidrs.edge },
    # Audio WebRTC: directo desde los clientes (no pasa por Cloudflare); LiveKit exige token propio
    { description = "LiveKit media TCP (respaldo)", protocol = "tcp", from_port = 7881, to_port = 7881, cidr_ipv4 = "0.0.0.0/0" },
    { description = "LiveKit media UDP", protocol = "udp", from_port = 7882, to_port = 7882, cidr_ipv4 = "0.0.0.0/0" },
    { description = "Node Exporter para Prometheus", protocol = "tcp", from_port = 9100, to_port = 9100, cidr_ipv4 = local.cidrs.infra },
    { description = "cAdvisor para Prometheus", protocol = "tcp", from_port = 9180, to_port = 9180, cidr_ipv4 = local.cidrs.infra },
  ]
}

# ---------- Nodo 3: infra ----------
module "infra" {
  source    = "./modules/node"
  providers = { aws = aws.infra }

  name                 = "infra"
  vpc_cidr             = local.cidrs.infra
  private_ip           = local.private_ips.infra
  availability_zone_id = var.availability_zone_id
  instance_type        = var.instance_type
  root_volume_gb       = var.root_volume_gb
  elastic_ip           = false # Nadie le llega desde internet: la IP automática es solo para salir
  budget_alert_email   = var.budget_alert_email

  ingress_rules = [
    { description = "RabbitMQ desde edge (outbox workers)", protocol = "tcp", from_port = 5672, to_port = 5672, cidr_ipv4 = local.cidrs.edge },
    { description = "RabbitMQ desde realtime (consumidores)", protocol = "tcp", from_port = 5672, to_port = 5672, cidr_ipv4 = local.cidrs.realtime },
    { description = "Payments desde Kong", protocol = "tcp", from_port = 8003, to_port = 8003, cidr_ipv4 = local.cidrs.edge },
  ]
}

# ---------- Peering: malla completa entre los tres nodos ----------
module "peering_edge_realtime" {
  source    = "./modules/peering"
  providers = { aws.requester = aws.edge, aws.accepter = aws.realtime }

  name   = "edge-realtime"
  region = var.region
  requester = {
    vpc_id         = module.edge.vpc_id
    vpc_cidr       = module.edge.vpc_cidr
    route_table_id = module.edge.route_table_id
  }
  accepter = {
    account_id     = module.realtime.account_id
    vpc_id         = module.realtime.vpc_id
    vpc_cidr       = module.realtime.vpc_cidr
    route_table_id = module.realtime.route_table_id
  }
}

module "peering_edge_infra" {
  source    = "./modules/peering"
  providers = { aws.requester = aws.edge, aws.accepter = aws.infra }

  name   = "edge-infra"
  region = var.region
  requester = {
    vpc_id         = module.edge.vpc_id
    vpc_cidr       = module.edge.vpc_cidr
    route_table_id = module.edge.route_table_id
  }
  accepter = {
    account_id     = module.infra.account_id
    vpc_id         = module.infra.vpc_id
    vpc_cidr       = module.infra.vpc_cidr
    route_table_id = module.infra.route_table_id
  }
}

module "peering_realtime_infra" {
  source    = "./modules/peering"
  providers = { aws.requester = aws.realtime, aws.accepter = aws.infra }

  name   = "realtime-infra"
  region = var.region
  requester = {
    vpc_id         = module.realtime.vpc_id
    vpc_cidr       = module.realtime.vpc_cidr
    route_table_id = module.realtime.route_table_id
  }
  accepter = {
    account_id     = module.infra.account_id
    vpc_id         = module.infra.vpc_id
    vpc_cidr       = module.infra.vpc_cidr
    route_table_id = module.infra.route_table_id
  }
}

# ---------- DNS (solo en el corte: ver var.manage_dns) ----------
resource "cloudflare_record" "api" {
  count = var.manage_dns ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "api"
  type    = "A"
  content = module.edge.public_ip
  proxied = true
  comment = "Kong (nodo edge). Administrado por Terraform"
}

# Un Security Group por nodo y uno para el RDS. Las reglas entre nodos apuntan al GRUPO de origen
# (referenced_security_group_id), no a rangos de IP: "el RDS acepta 5432 desde el grupo de edge".
# Todo lo que no está acá queda cerrado. Las reglas son recursos sueltos (no inline) para que dos grupos
# puedan referenciarse entre sí sin ciclos.

resource "aws_security_group" "node" {
  for_each = toset(local.nodes)

  name        = "discordia-${each.key}"
  description = "Nodo ${each.key} de Discordia"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "discordia-${each.key}" }
}

resource "aws_security_group" "rds" {
  name        = "discordia-rds"
  description = "RDS de Discordia: solo los tres nodos"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "discordia-rds" }
}

locals {
  # sg: grupo que recibe la regla. from: grupo de origen (nodo) o cidr (rango de IPs)
  ingress_rules = concat(
    # Kong con TLS (Cloudflare Origin Certificate), solo desde Cloudflare
    [for cidr in local.cloudflare_ipv4 : {
      sg = "edge", port = 443, protocol = "tcp", cidr = cidr, from = null, description = "Kong HTTPS desde Cloudflare"
    }],
    [
      # Temporal: Chat y Voice consultan can-send / can-connect hasta tener la foto de permisos por eventos
      { sg = "edge", port = 8002, protocol = "tcp", from = "realtime", cidr = null, description = "Server-Roles internal desde realtime" },

      { sg = "realtime", port = 3000, protocol = "tcp", from = "edge", cidr = null, description = "Chat-Engine desde Kong" },
      { sg = "realtime", port = 8082, protocol = "tcp", from = "edge", cidr = null, description = "Voice-Signaling desde Kong" },
      { sg = "realtime", port = 3001, protocol = "tcp", from = "edge", cidr = null, description = "Notification desde Kong" },
      { sg = "realtime", port = 7880, protocol = "tcp", from = "edge", cidr = null, description = "Senalizacion de LiveKit desde Kong" },
      # Audio WebRTC: directo desde los clientes (no pasa por Cloudflare); LiveKit exige token propio
      { sg = "realtime", port = 7881, protocol = "tcp", from = null, cidr = "0.0.0.0/0", description = "LiveKit media TCP (respaldo)" },
      { sg = "realtime", port = 7882, protocol = "udp", from = null, cidr = "0.0.0.0/0", description = "LiveKit media UDP" },

      { sg = "infra", port = 5672, protocol = "tcp", from = "edge", cidr = null, description = "RabbitMQ desde edge (outbox workers)" },
      { sg = "infra", port = 5672, protocol = "tcp", from = "realtime", cidr = null, description = "RabbitMQ desde realtime (consumidores)" },
      { sg = "infra", port = 8003, protocol = "tcp", from = "edge", cidr = null, description = "Payments desde Kong" },

      # Prometheus (infra) lee Node Exporter y cAdvisor de los otros nodos
      { sg = "edge", port = 9100, protocol = "tcp", from = "infra", cidr = null, description = "Node Exporter para Prometheus" },
      { sg = "edge", port = 9180, protocol = "tcp", from = "infra", cidr = null, description = "cAdvisor para Prometheus" },
      { sg = "realtime", port = 9100, protocol = "tcp", from = "infra", cidr = null, description = "Node Exporter para Prometheus" },
      { sg = "realtime", port = 9180, protocol = "tcp", from = "infra", cidr = null, description = "cAdvisor para Prometheus" },

      # RDS: Auth y Server-Roles (edge), Notification (realtime), Payments (infra)
      { sg = "rds", port = 5432, protocol = "tcp", from = "edge", cidr = null, description = "Postgres desde edge" },
      { sg = "rds", port = 5432, protocol = "tcp", from = "realtime", cidr = null, description = "Postgres desde realtime" },
      { sg = "rds", port = 5432, protocol = "tcp", from = "infra", cidr = null, description = "Postgres desde infra" },
    ]
  )

  security_group_ids = merge(
    { for name, sg in aws_security_group.node : name => sg.id },
    { rds = aws_security_group.rds.id },
  )
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = {
    for rule in local.ingress_rules :
    "${rule.sg}-${rule.protocol}-${rule.port}-${coalesce(rule.from, rule.cidr)}" => rule
  }

  security_group_id            = local.security_group_ids[each.value.sg]
  description                  = each.value.description
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  cidr_ipv4                    = each.value.cidr
  referenced_security_group_id = each.value.from == null ? null : aws_security_group.node[each.value.from].id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = local.security_group_ids

  security_group_id = each.value
  description       = "Salida a internet (imagenes, Auth0, Atlas) y a los otros nodos"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Discordia en tres EC2 dentro de una VPC (network.tf), más el RDS que ya existe:
#   edge     → Kong, Auth (+ worker), Server-Roles (+ worker), Redis de Kong
#   realtime → Chat, Voice, LiveKit, Notification, Redis de chat y voz
#   infra    → RabbitMQ, Payments, Prometheus y Grafana
#   los tres → Node Exporter y cAdvisor (métricas que lee el Prometheus de infra)
#   RDS      → Postgres (auth_db, server_roles_db, notification_db, payments_db), en las subnets de datos
# Afuera: Cloudflare (DNS + proxy + Pages) y MongoDB Atlas M0 (historial del chat).

module "edge" {
  source = "./modules/node"

  name              = "edge"
  subnet_id         = aws_subnet.public.id
  private_ip        = local.private_ips.edge
  security_group_id = aws_security_group.node["edge"].id
  instance_type     = var.instance_type
  root_volume_gb    = var.root_volume_gb
  elastic_ip        = true # api.discordia.lol apunta acá
  imds_hop_limit    = 2    # Auth y Server-Roles leen el rol (S3) desde Docker: necesitan un salto más
}

module "realtime" {
  source = "./modules/node"

  name              = "realtime"
  subnet_id         = aws_subnet.public.id
  private_ip        = local.private_ips.realtime
  security_group_id = aws_security_group.node["realtime"].id
  instance_type     = var.instance_type
  root_volume_gb    = var.root_volume_gb
  elastic_ip        = true # NODE_IP de LiveKit y allowlist de MongoDB Atlas
}

module "infra" {
  source = "./modules/node"

  name              = "infra"
  subnet_id         = aws_subnet.public.id
  private_ip        = local.private_ips.infra
  security_group_id = aws_security_group.node["infra"].id
  instance_type     = var.instance_type
  root_volume_gb    = var.root_volume_gb
  elastic_ip        = false # Nadie le llega desde internet: la IP automática es solo para salir
}

# ---------- RDS ----------
# El RDS ya existe y se mueve a esta VPC con la AWS CLI (ver README: grupo de subnets discordia-data y
# Security Group discordia-rds). Terraform no lo administra: solo lee su endpoint, así un error en el
# código nunca puede borrar la base.
data "aws_db_instance" "main" {
  db_instance_identifier = var.rds_identifier
}

# ---------- Alerta de gasto ----------
# Mide el costo neto (descontados los créditos): avisa apenas la cuenta empieza a gastar plata real.
resource "aws_budgets_budget" "net_spend" {
  name         = "discordia-gasto-real"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
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

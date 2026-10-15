variable "name" {
  description = "Nombre del nodo (edge, realtime, infra)"
  type        = string
}

variable "vpc_cidr" {
  description = "Rango de la VPC del nodo; no puede superponerse con el de los otros nodos (peering)"
  type        = string
}

variable "private_ip" {
  description = "IP privada fija de la EC2, dentro de la subnet (primer /24 libre del rango: x.x.1.0/24)"
  type        = string
}

variable "availability_zone_id" {
  description = "AZ ID (ej. use1-az1), igual en todas las cuentas"
  type        = string
}

variable "instance_type" {
  type = string
}

variable "root_volume_gb" {
  type = number
}

variable "elastic_ip" {
  description = "Si el nodo necesita una IP pública fija (origen de Cloudflare, NODE_IP de LiveKit)"
  type        = bool
  default     = false
}

variable "ingress_rules" {
  description = "Puertos de entrada del nodo. Todo lo que no esté acá queda cerrado."
  type = list(object({
    description = string
    protocol    = string # tcp | udp
    from_port   = number
    to_port     = number
    cidr_ipv4   = string
  }))
  default = []
}

variable "budget_alert_email" {
  description = "Mail para la alerta de gasto neto (después de los créditos) de la cuenta"
  type        = string
}

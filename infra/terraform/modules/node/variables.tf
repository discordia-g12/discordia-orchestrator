variable "name" {
  description = "Nombre del nodo (edge, realtime, infra)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet pública de la VPC donde va la EC2"
  type        = string
}

variable "private_ip" {
  description = "IP privada fija de la EC2, dentro de la subnet"
  type        = string
}

variable "security_group_id" {
  description = "Security Group del nodo (las reglas se definen en security.tf de la raíz)"
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

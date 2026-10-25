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

variable "imds_hop_limit" {
  description = <<-EOT
    Saltos permitidos para llegar al servicio de metadata (IMDSv2). Con 1 solo lo alcanza el host; los
    contenedores de Docker necesitan 2 para leer las credenciales del rol (ej. S3 en el nodo edge).
    null: no se toca (queda el valor que trae la AMI).
  EOT
  type        = number
  default     = null
}

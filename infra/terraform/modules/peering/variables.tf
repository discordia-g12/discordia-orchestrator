variable "name" {
  description = "Nombre de la conexión (ej. edge-realtime)"
  type        = string
}

variable "region" {
  type = string
}

variable "requester" {
  description = "VPC que pide la conexión (cuenta del provider aws.requester)"
  type = object({
    vpc_id         = string
    vpc_cidr       = string
    route_table_id = string
  })
}

variable "accepter" {
  description = "VPC que acepta la conexión (cuenta del provider aws.accepter)"
  type = object({
    account_id     = string
    vpc_id         = string
    vpc_cidr       = string
    route_table_id = string
  })
}

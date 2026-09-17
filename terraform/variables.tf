variable "aws_region" {
  description = "La región de AWS donde se van a crear los recursos"
  type        = string
  default     = "us-east-1"
}

variable "ssh_and_web_location" {
  description = "Rango de IPs que pueden acceder a los puertos de la instancia"
  type        = string
  default     = "0.0.0.0/0" # Por defecto abierto a todo el mundo
}

variable "instance_type" {
  description = "El tipo de instancia EC2"
  type        = string
  default     = "t3.small" # Mejor usar t3.medium por la cantidad de contenedores pero es pago
}

variable "key_name" {
  description = "El nombre del par de claves SSH (Key Pair) creado en AWS para conectarse a la máquina"
  type        = string
  default     = "" # Dejar en blanco si sólo se usa Session Manager, o poner el nombre de tu clave .pem
}


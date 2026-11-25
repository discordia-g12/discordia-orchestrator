variable "region" {
  description = "Región de AWS de los tres nodos"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone_id" {
  description = <<-EOT
    AZ ID (no nombre) de la subnet pública, donde van las tres EC2 (y, si AWS lo elige, el RDS). Se usa el
    ID porque el nombre (us-east-1a) se asigna distinto en cada cuenta.
  EOT
  type        = string
  default     = "use1-az1"
}

variable "rds_availability_zone" {
  description = "Zona donde vive el RDS (no cambia al moverlo de VPC): el grupo de subnets necesita una subnet ahí. Es también la segunda zona que exige AWS"
  type        = string
  default     = "us-east-1f"
}

variable "aws_profile" {
  description = "Profile de ~/.aws/credentials de la cuenta de AWS (los tres nodos y el RDS)"
  type        = string
}

variable "rds_identifier" {
  description = "Identificador del RDS que ya existe (se mueve a la VPC con la CLI, ver README)"
  type        = string
  default     = "discordia-db-cluster"
}

variable "instance_type" {
  description = "Tipo de instancia de los tres nodos (elegible con los créditos del plan Free de AWS)"
  type        = string
  default     = "t3.micro"
}

variable "root_volume_gb" {
  description = "Disco de cada nodo, en GB (gp3)"
  type        = number
  default     = 20
}

variable "media_bucket_name" {
  description = "Bucket de avatares e íconos de servidor (el nombre es global en todo S3)"
  type        = string
  default     = "discordia-g12-media"
}

variable "media_allowed_referers" {
  description = <<-EOT
    Páginas desde las que se pueden ver avatares, íconos y banners (condición aws:Referer de la bucket policy).
    Abrir el link suelto o embeberlo en otro sitio da 403. La app mobile manda Referer https://app.discordia.lol/.
    No es una barrera fuerte (un cliente puede inventar la cabecera): corta el hotlinking y el acceso casual.
  EOT
  type        = list(string)
  default = [
    "https://app.discordia.lol/*",
    "https://backoffice.discordia.lol/*",
    "https://discordia-webapp.pages.dev/*",
    "https://*.discordia-webapp.pages.dev/*", # previews de Cloudflare Pages
    "http://localhost:5173/*",                # web en desarrollo contra producción
    "http://localhost:5174/*",                # backoffice en desarrollo
    "http://localhost:8081/*",                # app mobile en el navegador (expo start --web)
  ]
}

variable "budget_alert_email" {
  description = "Mail que recibe el aviso si alguna cuenta empieza a gastar plata real (pasados los créditos)"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID de discordia.lol en Cloudflare"
  type        = string
}

variable "manage_dns" {
  description = "Si Terraform administra api.discordia.lol (Kong) y app.discordia.lol (Pages)"
  type        = bool
  default     = true
}

variable "cloudflare_account_id" {
  description = "Account ID de Cloudflare (dueño de la zona discordia.lol y del proyecto de Pages)"
  type        = string
}

# ---------- Frontend (Cloudflare Pages) ----------

variable "webapp_github_owner" {
  description = "Organización de GitHub del repo de la SPA"
  type        = string
  default     = "discordia-g12"
}

variable "webapp_github_repo" {
  description = "Repo de la SPA"
  type        = string
  default     = "Discordia-WebApp"
}

variable "webapp_production_branch" {
  description = "Rama que Pages publica en producción"
  type        = string
  default     = "main"
}

variable "api_public_url" {
  description = "URL pública de la API (Kong detrás de Cloudflare), embebida en el build de la SPA"
  type        = string
  default     = "https://api.discordia.lol"
}

variable "auth0_domain" {
  description = "Tenant de Auth0 (valor público, va en el bundle)"
  type        = string
  default     = "dev-dppme5iaqg60gkmo.us.auth0.com"
}

variable "auth0_client_id" {
  description = "Client ID de la SPA en Auth0 (valor público, va en el bundle)"
  type        = string
  default     = "f2H8PhlKDl3KSIm64G5mHAeQih7iFyIP"
}

variable "auth0_backoffice_client_id" {
  description = <<-EOT
    Client ID de la aplicación "Discordia Backoffice" en Auth0 (SPA aparte de la web, valor público). Vacío, el
    backoffice publicado muestra el error de configuración en vez del login
  EOT
  type        = string
  default     = ""
}

variable "auth0_audience" {
  description = "Audience de la API en Auth0"
  type        = string
  default     = "https://api.discordia.com"
}

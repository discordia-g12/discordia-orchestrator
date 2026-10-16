# Una sola cuenta de AWS para los tres nodos y el RDS.
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

# TEMPORAL — borrar después del primer apply de la VPC única.
# El estado todavía tiene recursos creados con estos providers (las 3 VPCs y los peerings de la versión
# anterior). Terraform necesita encontrarlos para poder destruir esos recursos. Apuntan a la misma cuenta.
provider "aws" {
  alias   = "edge"
  region  = var.region
  profile = var.aws_profile
}

provider "aws" {
  alias   = "realtime"
  region  = var.region
  profile = var.aws_profile
}

provider "aws" {
  alias   = "infra"
  region  = var.region
  profile = var.aws_profile
}

# Token con permisos de Zone:DNS:Edit y Account:Cloudflare Pages:Edit (variable de entorno CLOUDFLARE_API_TOKEN)
provider "cloudflare" {}

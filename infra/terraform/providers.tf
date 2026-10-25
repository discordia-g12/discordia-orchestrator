# Una sola cuenta de AWS para los tres nodos y el RDS.
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

# Token con permisos de Zone:DNS:Edit y Account:Cloudflare Pages:Edit (variable de entorno CLOUDFLARE_API_TOKEN)
provider "cloudflare" {}

# Una cuenta de AWS por nodo: cada una usa su propia capa gratuita / créditos.
# Localmente cada provider usa un profile de ~/.aws/credentials; en HCP Terraform, las variables
# AWS_* del workspace con assume_role (ver README).

provider "aws" {
  alias   = "edge"
  region  = var.region
  profile = var.aws_profiles.edge

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias   = "realtime"
  region  = var.region
  profile = var.aws_profiles.realtime

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias   = "infra"
  region  = var.region
  profile = var.aws_profiles.infra

  default_tags {
    tags = local.common_tags
  }
}

# Token con permisos de Zone:DNS:Edit sobre discordia.lol (variable de entorno CLOUDFLARE_API_TOKEN)
provider "cloudflare" {}

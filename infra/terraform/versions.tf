terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
  }

  # Estado compartido por el equipo. Elegido: HCP Terraform (plan Free): guarda el estado, tiene
  # lock y las credenciales de las tres cuentas quedan como variables del workspace.
  # Crear la organización y el workspace en app.terraform.io, descomentar y correr `terraform init`.
  #
  # cloud {
  #   organization = "discordia-g12"
  #   workspaces {
  #     name = "discordia-prod"
  #   }
  # }
}

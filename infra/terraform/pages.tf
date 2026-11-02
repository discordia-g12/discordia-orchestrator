# Frontend (SPA de Discordia-WebApp) en Cloudflare Pages, plan Free.
# Pages compila desde GitHub en cada push a la rama de producción y sirve los estáticos desde su CDN.
# Como es de Cloudflare, app.discordia.lol puede ir proxied (nube naranja) sin el conflicto que tiene Vercel.
#
# Requisito manual (una vez): en el dashboard de Cloudflare, Workers & Pages → conectar la cuenta de
# GitHub e instalar la app de Cloudflare Pages en la organización discordia-g12 con acceso al repo.

resource "cloudflare_pages_project" "webapp" {
  account_id        = var.cloudflare_account_id
  name              = "discordia-webapp"
  production_branch = var.webapp_production_branch

  source {
    type = "github"
    config {
      owner                         = var.webapp_github_owner
      repo_name                     = var.webapp_github_repo
      production_branch             = var.webapp_production_branch
      production_deployment_enabled = true
      deployments_enabled           = true
      pr_comments_enabled           = false
      # Sin previews: apuntarían a la API de producción y Auth0 no tiene sus URLs permitidas
      preview_deployment_setting = "none"
    }
  }

  build_config {
    # Pages instala las dependencias solo (detecta package-lock.json) antes de este comando
    build_command   = "npm run build"
    destination_dir = "dist"
    root_dir        = ""
    build_caching   = true
  }

  deployment_configs {
    production {
      # Vite las embebe en el bundle al compilar: son valores públicos, no secretos
      environment_variables = {
        NODE_VERSION         = "22" # misma versión que el .nvmrc, el CI y el Dockerfile del repo (Expo SDK 58 pide 22)
        VITE_API_URL         = var.api_public_url
        VITE_AUTH0_DOMAIN    = var.auth0_domain
        VITE_AUTH0_CLIENT_ID = var.auth0_client_id
        VITE_AUTH0_AUDIENCE  = var.auth0_audience
        # Link "backoffice" del menú de usuario (solo lo ve el staff)
        VITE_BACKOFFICE_URL = "https://${local.backoffice_domain}"
      }
    }
  }
}

# Dominio propio: se asocia recién en el corte, junto con el registro DNS (hoy app apunta al monolito)
resource "cloudflare_pages_domain" "app" {
  count = var.manage_dns ? 1 : 0

  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.webapp.name
  domain       = "app.discordia.lol"
}

# Pages no crea el registro DNS del dominio propio: CNAME al subdominio *.pages.dev del proyecto
resource "cloudflare_record" "app" {
  count = var.manage_dns ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "app"
  type    = "CNAME"
  content = cloudflare_pages_project.webapp.subdomain
  proxied = true
  comment = "SPA en Cloudflare Pages. Administrado por Terraform"
}

# ---------- Backoffice del staff (apps/backoffice del mismo repo) ----------
# Otro proyecto de Pages sobre el mismo repo, con su propio dominio (Gateway/docs/ADR-002-Rol-Staff-Backoffice.md):
# no comparte origen con la web. Compila en cada push a la rama de producción, igual que la web.

locals {
  backoffice_domain = "backoffice.discordia.lol"
}

resource "cloudflare_pages_project" "backoffice" {
  account_id        = var.cloudflare_account_id
  name              = "discordia-backoffice"
  production_branch = var.webapp_production_branch

  source {
    type = "github"
    config {
      owner                         = var.webapp_github_owner
      repo_name                     = var.webapp_github_repo
      production_branch             = var.webapp_production_branch
      production_deployment_enabled = true
      deployments_enabled           = true
      pr_comments_enabled           = false
      # Sin previews: Auth0 no tiene sus URLs permitidas
      preview_deployment_setting = "none"
    }
  }

  build_config {
    build_command   = "npm run build:backoffice"
    destination_dir = "apps/backoffice/dist"
    root_dir        = ""
    build_caching   = true
  }

  deployment_configs {
    production {
      # Valores públicos (van en el bundle). El client ID es el de la aplicación "Discordia Backoffice" de Auth0,
      # no el de la web
      environment_variables = {
        NODE_VERSION         = "22"
        VITE_API_URL         = var.api_public_url
        VITE_AUTH0_DOMAIN    = var.auth0_domain
        VITE_AUTH0_CLIENT_ID = var.auth0_backoffice_client_id
        VITE_AUTH0_AUDIENCE  = var.auth0_audience
        VITE_APP_URL         = "https://app.discordia.lol"
        # Grafana no está publicado: se abre con el port forwarding de SSM (docs/ARQUITECTURA.md, sección 10)
        VITE_GRAFANA_URL = "http://localhost:3030"
      }
    }
  }
}

resource "cloudflare_pages_domain" "backoffice" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.backoffice.name
  domain       = local.backoffice_domain
}

resource "cloudflare_record" "backoffice" {
  zone_id = var.cloudflare_zone_id
  name    = "backoffice"
  type    = "CNAME"
  content = cloudflare_pages_project.backoffice.subdomain
  proxied = true
  comment = "Backoffice del staff en Cloudflare Pages. Administrado por Terraform"
}

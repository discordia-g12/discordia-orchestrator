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

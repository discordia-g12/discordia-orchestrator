# CD: GitHub Actions entra a AWS por OIDC y le ordena a cada nodo, por SSM, que despliegue la imagen nueva.
# No hay claves de AWS ni claves SSH guardadas en GitHub: cada job pide credenciales temporales (1 h) con el
# token OIDC que GitHub firma para ese run.
# Ver docs/ARQUITECTURA.md, sección 11 ("Seguridad del deploy").

data "aws_caller_identity" "current" {}

# Uno por cuenta y URL. AWS valida los tokens de GitHub con su propia CA: el thumbprint no hace falta.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Solo lo pueden asumir los workflows que corren en main de los repos de local.cd_repos.
# En un workflow reutilizable, el "sub" es el del repo que lo llama, no el del orquestador.
resource "aws_iam_role" "cd" {
  name                 = "discordia-cd"
  description          = "Deploy desde GitHub Actions (main) por SSM"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            for repo, id in local.cd_repos :
            "repo:discordia-g12@${local.github_org_id}/${repo}@${id}:ref:refs/heads/main"
          ]
        }
      }
    }]
  })
}

# Lo único que el rol puede correr en un nodo. Con AWS-RunShellScript, quien pudiera pushear a main de
# cualquiera de los repos corría lo que quisiera como root (y leía nodes.env). SSM rechaza los parámetros
# que no cumplen allowedPattern antes de llegar al nodo, así que {{ }} no puede inyectar comandos.
# En el contenido no puede aparecer "$" seguido de "{" (Terraform lo interpola): se usa $f, $(...), etc.
resource "aws_ssm_document" "deploy_service" {
  name          = "discordia-deploy-service"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy de un servicio: deploy/deploy-service.sh <imagen> <sha>"
    parameters = {
      service = { type = "String", allowedPattern = "^[a-z-]+$" }
      sha     = { type = "String", allowedPattern = "^[0-9a-f]{40}$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deployService"
      inputs = {
        timeoutSeconds = "900"
        # El pull primero: así corre la versión del script que está en main. Si falla, sigue con la del nodo.
        runCommand = [
          "export HOME=/root",
          "git -c safe.directory=/opt/discordia -C /opt/discordia pull --ff-only --quiet || echo 'aviso: git pull falló'",
          "/opt/discordia/deploy/deploy-service.sh {{ service }} {{ sha }}",
        ]
      }
    }]
  })
}

resource "aws_ssm_document" "deploy_config" {
  name          = "discordia-deploy-config"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy de la configuración del orquestador: deploy/deploy-config.sh <sha>"
    parameters = {
      sha = { type = "String", allowedPattern = "^[0-9a-f]{40}$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deployConfig"
      inputs = {
        timeoutSeconds = "900"
        # El script tal como está en ese commit (el del nodo puede ser viejo o no existir), en un archivo
        # temporal porque el script mueve el repo, y con él su propio archivo.
        runCommand = [
          "export HOME=/root",
          "set -e",
          "g='git -c safe.directory=/opt/discordia -C /opt/discordia'",
          "$g fetch --quiet origin main",
          "f=$(mktemp); trap 'rm -f $f' EXIT",
          "$g show {{ sha }}:deploy/deploy-config.sh > $f",
          "bash $f {{ sha }}",
        ]
      }
    }]
  })
}

# Permisos mínimos: correr esos dos documentos en los tres nodos, leer su resultado y buscar la instancia por
# tag. GetCommandInvocation, ListCommandInvocations y DescribeInstances no admiten permisos por recurso.
resource "aws_iam_role_policy" "cd" {
  name = "deploy-via-ssm"
  role = aws_iam_role.cd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunDeployOnNodes"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = concat(
          [aws_ssm_document.deploy_service.arn, aws_ssm_document.deploy_config.arn],
          [
            for id in [module.edge.instance_id, module.realtime.instance_id, module.infra.instance_id] :
            "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${id}"
          ],
        )
      },
      {
        Sid      = "ReadDeployResult"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Sid      = "FindNodeByTag"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
    ]
  })
}

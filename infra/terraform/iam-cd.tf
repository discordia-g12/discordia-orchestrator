# CD: GitHub Actions entra a AWS por OIDC y le ordena a cada nodo, por SSM, que despliegue la imagen nueva.
# No hay claves de AWS ni claves SSH guardadas en GitHub: cada job pide credenciales temporales (1 h) con el
# token OIDC que GitHub firma para ese run. Ver docs/TODO-CD.md.

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
            for repo in local.cd_repos : "repo:discordia-g12/${repo}:ref:refs/heads/main"
          ]
        }
      }
    }]
  })
}

# Permisos mínimos: mandar AWS-RunShellScript a los tres nodos, leer su resultado y buscar la instancia por tag.
# GetCommandInvocation, ListCommandInvocations y DescribeInstances no admiten permisos por recurso.
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
          ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"],
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

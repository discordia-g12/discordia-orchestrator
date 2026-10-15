# Infraestructura de Discordia (3 nodos, 3 cuentas de AWS)

Cada nodo vive en la cuenta de AWS de un integrante (plan Free con créditos) y en su propia VPC. Las
tres VPCs se conectan por **VPC peering** (gratis), así el tráfico entre nodos no pasa por internet.

| Nodo | VPC | IP privada | IP pública | Qué corre |
|---|---|---|---|---|
| edge | 10.10.0.0/16 | 10.10.1.10 | Elastic IP (origen de Cloudflare) | Kong, Auth (+worker), Server-Roles (+worker), Postgres, Redis de Kong |
| realtime | 10.20.0.0/16 | 10.20.1.10 | Elastic IP (LiveKit, Atlas) | Chat, Voice, LiveKit, Notification, Postgres, Redis de chat y voz |
| infra | 10.30.0.0/16 | 10.30.1.10 | Automática (solo salida) | RabbitMQ, Payments (+Postgres), Prometheus, Grafana |

El frontend (SPA) va en **Cloudflare Pages** (plan Free, `pages.tf`): compila `Discordia-WebApp` en cada
push a `main` y lo sirve desde `app.discordia.lol`, independiente de los nodos.

El único puerto abierto a internet es el audio de LiveKit (7881/tcp, 7882/udp). Kong (443) solo
acepta las IPs de Cloudflare. El admin de Kong, RabbitMQ, Prometheus y Grafana no se publican.

## Costo
Todo se paga con los créditos del plan Free de cada cuenta (aprox. por cuenta: t3.small ~$15/mes +
IPv4 ~$3.65/mes + 20 GB gp3 ~$1.60/mes). Cada cuenta tiene un **budget de $1 sobre el gasto neto**:
si llega un mail, algo se está cobrando fuera de los créditos.

Importante: cuando se terminan los créditos o pasan los 6 meses del plan Free, AWS suspende la cuenta.
Verificar la fecha de fin de cada cuenta (Billing → Free Tier) contra la fecha de entrega.

## Antes del primer `apply`
1. En cada una de las tres cuentas: un usuario IAM (o SSO) para Terraform y su profile en
   `~/.aws/credentials` (`discordia-edge`, `discordia-realtime`, `discordia-infra`).
2. Confirmar que `use1-az1` tiene t3.small en las tres cuentas
   (`aws ec2 describe-instance-type-offerings --location-type availability-zone-id --filters Name=instance-type,Values=t3.small --profile <p>`).
3. Un API token de Cloudflare en `CLOUDFLARE_API_TOKEN` con permisos `Zone:DNS:Edit` sobre discordia.lol
   y `Account:Cloudflare Pages:Edit`.
4. En el dashboard de Cloudflare (Workers & Pages): conectar GitHub e instalar la app de Cloudflare
   Pages en la organización `discordia-g12` con acceso a `Discordia-WebApp` (Terraform no puede hacerlo).
5. Estado compartido: crear la organización en HCP Terraform (Free) y descomentar el bloque `cloud`
   de `versions.tf`. Hasta entonces el estado queda local: que lo aplique **una sola persona**.
6. `cp terraform.tfvars.example terraform.tfvars` y completar.

## Aplicar
```bash
terraform init
terraform plan    # revisar: ~45 recursos a crear, 0 a destruir
terraform apply
terraform output  # IPs de los nodos y el comando de SSM para entrar a cada uno
```

`manage_dns` queda en `false` hasta el corte. Mientras tanto la SPA ya queda publicada en
`https://discordia-webapp.pages.dev` para probarla.

## Corte de DNS (fase 5)
Hoy `api` y `app` ya existen en Cloudflare apuntando al monolito, y Terraform no puede crear un
registro que ya existe. En el corte:
1. Borrar a mano los registros viejos `api` (A) y `app` (A a la EC2 vieja). `app` cambia de tipo
   (A → CNAME), así que no sirve importarlo.
2. `manage_dns = true` en `terraform.tfvars` y `terraform apply`: crea `api` (A al edge, proxied),
   `app` (CNAME a Pages, proxied) y asocia `app.discordia.lol` al proyecto de Pages.
3. En Auth0, agregar `https://app.discordia.lol` en Allowed Callback URLs, Logout URLs y Web Origins.

## Entrar a un nodo
Sin SSH ni puerto 22: Session Manager (`terraform output ssm_connect`). Requiere el plugin de SSM de
la AWS CLI.

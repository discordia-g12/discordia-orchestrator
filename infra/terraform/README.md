# Infraestructura de Discordia (una cuenta, una VPC, tres EC2 + RDS)

```
VPC 10.0.0.0/16
├── public  10.0.1.0/24   use1-az1   EC2 edge 10.0.1.10 · realtime 10.0.1.20 · infra 10.0.1.30
├── data-a  10.0.64.0/24  use1-az1   ┐ RDS (sin ruta a internet)
└── data-b  10.0.66.0/24  us-east-1f ┘ (zona del RDS; AWS exige 2 zonas en el grupo de subnets)
```

| Nodo | IP privada | IP pública | Qué corre |
|---|---|---|---|
| edge | 10.0.1.10 | Elastic IP (origen de Cloudflare) | Kong, Auth (+worker), Server-Roles (+worker), Redis de Kong |
| realtime | 10.0.1.20 | Elastic IP (LiveKit, Atlas) | Chat, Voice, LiveKit, Notification, Redis de chat y voz |
| infra | 10.0.1.30 | Automática (solo salida) | RabbitMQ, Payments, Prometheus, Grafana |
| RDS | subnets de datos | — | Postgres: `auth_db`, `server_roles_db`, `notification_db`, `payments_db` |

El frontend (SPA) va en **Cloudflare Pages** (`pages.tf`).

- **Security Groups** (`security.tf`): uno por nodo y uno para el RDS. Las reglas apuntan al grupo de origen
  ("el RDS acepta 5432 desde el grupo de edge, realtime e infra"). Kong (443) solo acepta las IPs de
  Cloudflare; el único puerto abierto a internet es el audio de LiveKit (7881/tcp, 7882/udp).
- **El RDS no lo crea ni lo administra Terraform**: ya existía. Terraform crea su red (grupo de subnets
  `discordia-data` y Security Group `discordia-rds`) y solo lee su endpoint (`terraform output rds_endpoint`).
  Así un error en el código nunca puede borrar la base.
- **Imágenes en S3** (`storage.tf`): bucket `discordia-g12-media`.
  - `avatars/` y `server-icons/` (avatares, íconos y banners) se leen sin firma, pero **solo desde las páginas
    de Discordia**: la bucket policy exige un `Referer` de `media_allowed_referers` (la web, el backoffice, los
    previews de Pages y localhost). Abrir el link suelto o embeberlo en otro sitio da 403. La app mobile manda
    `Referer: https://app.discordia.lol/` (`apps/mobile/src/utils/remoteImage.ts`). No es una barrera fuerte:
    alguien con curl puede inventar la cabecera.
  - `attachments/` (adjuntos del chat y de los DMs) es **privado**: Chat-Engine guarda la URL sin firma y la
    entrega firmada (SigV4, 24 h) solo dentro del mensaje de ese canal.

  Cada servicio escribe con su propio usuario IAM (`discordia-auth-media`, `discordia-server-roles-media`,
  `discordia-chat-media`), limitado a su prefijo: no usa el rol de la EC2, así que funciona en cualquier
  nodo. Después del `apply`:
  1. Crear las access keys con los comandos de `terraform output media_access_key_commands` (no se crean
     en Terraform para que el secreto no quede en el estado).
  2. Cargar en el `nodes.env` del nodo de cada servicio `S3_BUCKET` y `S3_PUBLIC_BASE_URL`
     (`terraform output media_bucket`) y sus claves: `AUTH_AWS_ACCESS_KEY_ID` / `AUTH_AWS_SECRET_ACCESS_KEY`
     y `SERVER_ROLES_AWS_ACCESS_KEY_ID` / `SERVER_ROLES_AWS_SECRET_ACCESS_KEY`. Chat-Engine (nodo realtime)
     solo necesita `S3_BUCKET` y `CHAT_AWS_ACCESS_KEY_ID` / `CHAT_AWS_SECRET_ACCESS_KEY`.

  Si falla la bucket policy con `AccessDenied`, revisar que el *Block Public Access* de la cuenta no esté
  activo (S3 → Block Public Access settings for this account).
- **Budget de $1 sobre el gasto neto**: si llega un mail, algo se está cobrando fuera de los créditos.


## Entrar a un nodo
Se utiliza Session Manager (`terraform output ssm_connect`). Requiere el plugin de SSM de la AWS CLI.

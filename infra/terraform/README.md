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
- **Budget de $1 sobre el gasto neto**: si llega un mail, algo se está cobrando fuera de los créditos.


## Entrar a un nodo
Se utiliza Session Manager (`terraform output ssm_connect`). Requiere el plugin de SSM de la AWS CLI.

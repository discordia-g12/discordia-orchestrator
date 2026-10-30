# discordia-orchestrator

Repo raíz de Discordia (grupo 12, Ingeniería del Software II). Junta todos los repos como submódulos, el detalle de cómo se levanta el sistema completo, en local y en
producción, la infraestructura (Terraform), el despliegue continuo y la documentación de arquitectura.

Cada servicio se puede levantar solo, desde su propio repo: ver el README de cada uno. Este repo sirve para
levantarlos **todos juntos**.

## Repos

| Carpeta (submódulo) | Qué es | Stack | Nodo en producción |
|---|---|---|---|
| `Gateway` | API Gateway: valida los tokens de Auth0, rate limiting, enrutamiento | Kong 3.4 (Lua) | edge |
| `Auth-User-Service` | Usuarios y perfiles | Python, FastAPI, PostgreSQL | edge |
| `Server-Roles-Core-Service` | Servidores, canales, roles, permisos, moderación | Python, FastAPI, PostgreSQL | edge |
| `Chat-Engine-Service` | Mensajería en tiempo real (WebSocket) e historial | Node.js, Fastify, MongoDB, Redis | realtime |
| `Voice-Signaling-Session-Service` | Canales de voz: tokens de LiveKit y presencia | Node.js, Fastify, Redis, LiveKit | realtime |
| `Notification-Audit-Metrics-Service` | Notificaciones, auditoría y métricas (esqueleto) | Node.js, Fastify, PostgreSQL | realtime |
| `Payments-Monetization-Service` | Premium, puntos y boosts (esqueleto) | Python, FastAPI, PostgreSQL | infra |
| `Discordia-WebApp` | Cliente web y app mobile (monorepo) | React + Vite, Expo / React Native | Cloudflare Pages |
| `observability` | Dashboards y configuración de Prometheus y Grafana | Grafana, Prometheus | infra |
| `org-docs` | Repo `.github` de la organización: perfil y ADRs generales | — | — |

Los servicios se hablan por HTTP a través de Kong y por eventos en RabbitMQ (patrón Outbox). El detalle está
en [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md).

## Clonar

```bash
git clone --recurse-submodules https://github.com/discordia-g12/discordia-orchestrator.git
cd discordia-orchestrator

# Si ya estaba clonado sin submódulos
git submodule update --init --recursive
```

Cada submódulo queda en el commit que fija este repo. Para trabajar en uno, entrar a su carpeta y cambiar de
rama (`git -C Chat-Engine-Service switch develop`).

## Levantar todo en local

`deploy/docker-compose.yml` es el mismo compose que corre en producción, separado en tres nodos (*profiles*
`edge`, `realtime` e `infra`). Con el profile `local` además levanta PostgreSQL y MongoDB en contenedores, en
lugar del RDS y de Atlas.

**Requisitos:** Docker con memoria de sobra: los límites de los contenedores suman unos 4 GB, así que conviene
darle 6 GB a Docker Desktop. También estos puertos libres en el host: 3000, 3001, 5432, 5672,
7880 a 7882, 8000, 8002, 8003, 8082, 8443, 9090, 9100, 9180 y 3030. Si algún servicio está corriendo con el
compose de su propio repo, bajarlo antes.

```bash
cp deploy/.env.example deploy/.env      # COMPOSE_PROFILES=edge,realtime,infra,local
docker compose -f deploy/docker-compose.yml up -d --build
docker compose -f deploy/docker-compose.yml ps   # esperar a que todos estén "healthy"
```

| Qué | Dónde |
|---|---|
| API (Kong) | `http://localhost:8000` y `https://localhost:8443` (certificado autofirmado) |
| Grafana | `http://localhost:3030` (usuario `admin`, contraseña `dev-grafana`) |
| Prometheus | `http://localhost:9090` |
| Panel de RabbitMQ | `http://localhost:15672` |
| PostgreSQL | `localhost:5432` (las cuatro bases: `auth_db`, `server_roles_db`, `notification_db`, `payments_db`) |

Probarlo:

```bash
curl localhost:8000/livez                      # Kong
curl -i localhost:8000/api/v1/users/me         # 401: hace falta un token de Auth0
```

Para usarlo como usuario, levantar la web desde `Discordia-WebApp` (`npm install && npm run dev`, en
`http://localhost:5173`): apunta a `localhost:8000` por defecto y el login es el de Auth0.

Bajar todo: `docker compose -f deploy/docker-compose.yml down` (con `-v` también borra los datos).

Más detalle (nodos, redes, cómo probar que la caída de un nodo no tumba a los otros) en
[`deploy/README.md`](deploy/README.md).

### El `docker-compose.yml` de la raíz

Es el compose anterior a la separación en nodos. Incluye la web (con recarga en caliente si se copia
`docker-compose.override.yml.example` a `docker-compose.override.yml`), pero sus servicios se conectan a la
base que diga `RDS_HOST`, que en `.env.example` es el RDS de producción. Para desarrollar, usar
`deploy/docker-compose.yml`. Está registrado como deuda técnica (L1 en
[`docs/DEUDA-TECNICA.md`](docs/DEUDA-TECNICA.md)).

## Producción y despliegue

- **Infraestructura:** tres EC2 (edge, realtime e infra) en una VPC, un RDS, un bucket S3, el DNS y Cloudflare
  Pages, en Terraform: [`infra/terraform/`](infra/terraform/).
- **Despliegue continuo:** cada merge a `main` de un servicio lo despliega solo en su nodo (GitHub Actions →
  OIDC → SSM), con healthcheck y rollback. Un merge a `main` de este repo que toque `deploy/`, `livekit/`,
  `rabbitmq/` u `observability` despliega la configuración en los tres nodos. Ver
  [`docs/ARQUITECTURA.md`, sección 11](docs/ARQUITECTURA.md#11-despliegue).

## Estructura

```text
deploy/               compose de los tres nodos, scripts del CD (deploy-service.sh, deploy-config.sh)
.github/workflows/    deploy.yml (reutilizable, lo llama el CI de cada servicio) y deploy-config.yml
infra/terraform/      infraestructura de AWS y Cloudflare
livekit/              configuración del servidor de LiveKit
rabbitmq/             configuración de RabbitMQ
docs/                 arquitectura, bitácora del proyecto y deuda técnica
docker-compose.yml    compose de desarrollo anterior (ver arriba)
init-dbs.sql          crea las cuatro bases en el PostgreSQL local
```

## Documentación

| Documento | Contenido |
|---|---|
| [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) | Arquitectura, red, comunicación entre servicios, resiliencia, despliegue y decisiones |
| [`docs/BITACORA.md`](docs/BITACORA.md) | Evolución semanal del backlog |
| [`docs/DEUDA-TECNICA.md`](docs/DEUDA-TECNICA.md) | Lo que queda pendiente a propósito, con el motivo |
| [`deploy/README.md`](deploy/README.md) | Compose por nodo, local y producción |
| `org-docs/docs/architecture/decisions/` | ADRs generales (microservicios, stack, bases, outbox, gateway, WebSockets, voz, sagas, clientes) |

Cada servicio tiene además sus propios ADRs en su carpeta `docs/`.

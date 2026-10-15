# Despliegue por nodo

Un solo compose (`deploy/docker-compose.yml`) para los tres nodos, igual en local y en producción.

| Nodo (profile) | Red | Servicios | Puertos publicados (para los otros nodos) |
|---|---|---|---|
| `edge` | `edge` | Kong + Redis, Auth (+worker), Server-Roles (+worker), Postgres (`auth_db`, `server_roles_db`) | 443/8443 (Kong), 8002 (Server-Roles internal) |
| `realtime` | `realtime` | Chat + Redis, Voice + Redis, LiveKit, Notification, Postgres (`notification_db`) | 3000, 8082, 3001, 7880, 7881, 7882/udp |
| `infra` | `infra` | RabbitMQ, Payments, Postgres (`payments_db`), Prometheus, Grafana | 5672, 8003 |
| los tres | (default) | Node Exporter, cAdvisor (métricas de la máquina y de sus contenedores) | 9100, 9180 (solo para infra) |

**Observabilidad:** Prometheus (infra) lee los exportadores de los tres nodos por IP:puerto
(`observability/prometheus.yml.tmpl`) y Grafana usa los dashboards del submódulo `observability`.
Los paneles quedan en el host: Grafana en `http://localhost:3030` (usuario `admin`, contraseña
`GRAFANA_ADMIN_PASSWORD`; en local `dev-grafana`) y Prometheus en `http://localhost:9090` (*Status →
Targets*). En producción se entra por port forwarding de SSM:
`aws ssm start-session --target <id de infra> --document-name AWS-StartPortForwardingSession --parameters portNumber=3030,localPortNumber=3030`.

**Cada nodo tiene su propia red de Docker.** Los contenedores de un nodo se ven por nombre entre ellos,
pero no ven los de otro nodo: lo que cruza de un nodo a otro va a la IP del host y al puerto publicado,
igual que entre máquinas distintas.

- Local: la IP del host es `host.docker.internal` (default de `EDGE_HOST`, `REALTIME_HOST`, `INFRA_HOST`).
- Producción: las IPs privadas de las EC2 (`terraform output nodes`).

Qué nodos se levantan lo decide `COMPOSE_PROFILES`. Fuera de los nodos: la SPA en Cloudflare Pages y el
historial del chat en MongoDB Atlas (profile `local` = Mongo en contenedor, solo para desarrollo).

## Local: los tres nodos en tu máquina

```bash
cp deploy/.env.example deploy/.env   # COMPOSE_PROFILES=edge,realtime,infra,local
docker compose -f deploy/docker-compose.yml up -d --build
```

La API queda en `http://localhost:8000` (y con TLS autofirmado en `https://localhost:8443`). No
levantar al mismo tiempo el compose de la raíz: usan los mismos puertos.

**Probar que un nodo no tumba a los otros** (nombres de servicio: ver la tabla):

```bash
docker compose -f deploy/docker-compose.yml stop rabbitmq payments-service infra-db   # "apagar" infra
# el chat y la voz siguen andando; /readyz del chat (localhost:3000/readyz) muestra rabbitmq: disconnected
docker compose -f deploy/docker-compose.yml start rabbitmq payments-service infra-db
```

Para verificar el aislamiento entre redes: desde un contenedor de edge, un nombre de otro nodo no resuelve
(`docker compose -f deploy/docker-compose.yml exec auth-service python -c "import socket; socket.gethostbyname('rabbitmq')"`
falla), pero `host.docker.internal:5672` sí responde.

## Producción (en cada EC2)

1. Entrar por SSM (`terraform output ssm_connect`) y clonar el orquestador con submódulos en `/opt/discordia`.
2. Crear `/etc/discordia/nodes.env` (permisos 600) con `COMPOSE_PROFILES=<nodo>`, las IPs privadas de los
   otros nodos y los secretos de ese nodo (lista completa en `.env.example`). **Todos los secretos tienen
   que estar definidos**: los defaults del compose son solo para desarrollo.
3. Solo edge: `deploy/gateway.env` (de `gateway.env.example`) y el Origin Certificate de Cloudflare en
   `deploy/tls/` (`origin.pem`, `origin.key`).
4. Levantar en orden (infra → realtime → edge). En el servidor no se construye nada: se bajan las imágenes
   que publicó el CI de cada repo en GHCR (`REGISTRY` y un `<SERVICIO>_TAG` por servicio en `nodes.env`):
   ```bash
   C="docker compose -f /opt/discordia/deploy/docker-compose.yml --env-file /etc/discordia/nodes.env"
   $C pull
   $C up -d --no-build
   ```

## Desplegar un servicio solo

Cada push a `main`/`develop` de un repo publica `ghcr.io/discordia-g12/<servicio>:<sha>` (y `:<rama>`).
Para desplegar esa versión, en la EC2 de su nodo: cambiar su `<SERVICIO>_TAG` en `nodes.env` por el SHA y

```bash
$C pull auth-service
$C up -d --no-build --no-deps auth-service
```

Los demás servicios no se tocan. Para volver atrás, el SHA anterior.

Si los paquetes de GHCR son privados, la EC2 necesita `docker login ghcr.io` con un token de GitHub de
solo lectura (`read:packages`). Si los repos son públicos, conviene hacer públicas también las imágenes.

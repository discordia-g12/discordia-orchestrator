# Despliegue por nodo

Un solo compose (`deploy/docker-compose.yml`) para los tres nodos, igual en local y en producción.

| Nodo (profile) | Red | Servicios | Puertos publicados (para los otros nodos) |
|---|---|---|---|
| `edge` | `edge` | Kong + Redis, Auth (+worker), Server-Roles (+worker) | 443/8443 (Kong), 8002 (Server-Roles internal) |
| `realtime` | `realtime` | Chat + Redis, Voice + Redis, LiveKit, Notification | 3000, 8082, 3001, 7880, 7881, 7882/udp |
| `infra` | `infra` | RabbitMQ, Payments, Prometheus, Grafana | 5672, 8003 |
| los tres | (default) | Node Exporter, cAdvisor (métricas de la máquina y de sus contenedores) | 9100, 9180 (solo para infra) |

**Base de datos:** ningún nodo corre Postgres. Los cuatro servicios con base relacional usan el RDS
(`DB_HOST`), cada uno con su base: `auth_db`, `server_roles_db` (edge), `notification_db` (realtime) y
`payments_db` (infra). En local, el profile `local` levanta un Postgres que hace de RDS en el 5432 del host
(crea las bases con `init-dbs.sql`) y los servicios le llegan por `host.docker.internal:5432`.

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
historial del chat en MongoDB Atlas y el RDS (profile `local` = Mongo y Postgres en contenedor, solo
para desarrollo).

## Local: los tres nodos en tu máquina

```bash
cp deploy/.env.example deploy/.env   # COMPOSE_PROFILES=edge,realtime,infra,local
docker compose -f deploy/docker-compose.yml up -d --build
```

La API queda en `http://localhost:8000` (y con TLS autofirmado en `https://localhost:8443`). No
levantar al mismo tiempo el compose de la raíz: usan los mismos puertos (también el 5432).

**Probar que un nodo no tumba a los otros** (nombres de servicio: ver la tabla):

```bash
docker compose -f deploy/docker-compose.yml stop rabbitmq payments-service   # "apagar" infra
# el chat y la voz siguen andando; /readyz del chat (localhost:3000/readyz) muestra rabbitmq: disconnected
docker compose -f deploy/docker-compose.yml start rabbitmq payments-service
```

Para verificar el aislamiento entre redes: desde un contenedor de edge, un nombre de otro nodo no resuelve
(`docker compose -f deploy/docker-compose.yml exec auth-service python -c "import socket; socket.gethostbyname('rabbitmq')"`
falla), pero `host.docker.internal:5672` sí responde.

## Producción

### Despliegue automático (CD)

No hace falta entrar a los nodos para desplegar:

- **Un servicio:** al mergear a `main` de su repo, el CI corre los tests, publica
  `ghcr.io/discordia-g12/<servicio>:<sha>` y llama a `.github/workflows/deploy.yml` (de este repo). Ese
  workflow entra a AWS por OIDC y le ordena al nodo, por SSM, que corra `deploy-service.sh <imagen> <sha>`.
- **La configuración** (`deploy/**`, `livekit/**`, `rabbitmq/**` o el submódulo `observability`): al
  mergear a `main` de este repo, `.github/workflows/deploy-config.yml` corre `deploy-config.sh <sha>` en los
  tres nodos, en orden infra → realtime → edge. Se puede volver a correr a mano desde *Actions → Deploy
  config → Run workflow*.

Los dos scripts esperan a que los contenedores queden `healthy`. Si no quedan, vuelven a la versión anterior
y el job de GitHub falla. Cada deploy queda en `/var/log/discordia-deploy.log` del nodo. El detalle
(seguridad, rollback, limitaciones) está en [`docs/ARQUITECTURA.md`, sección 11](../docs/ARQUITECTURA.md#11-despliegue).

| Script | Uso | Qué hace |
|---|---|---|
| `deploy-service.sh` | `deploy-service.sh <imagen> <sha>` | Baja la imagen, cambia `<SERVICIO>_TAG` en `nodes.env` y recrea solo los contenedores de ese repo (`--no-deps`). Rollback al tag anterior si no queda `healthy` en 120 s |
| `deploy-config.sh` | `deploy-config.sh <sha>` | Lleva `/opt/discordia` a ese commit de `main`, corre `up -d` del nodo y recrea los contenedores cuyos archivos montados cambiaron. Rollback al commit anterior si el nodo no queda sano en 180 s |

Los dos corren como root, toman el mismo lock (un deploy por vez en cada nodo) y aceptan solo el SHA
completo (40 caracteres).

### Preparar un nodo nuevo (una sola vez)

1. Entrar por SSM (`terraform output ssm_connect`) y clonar el orquestador en `main`, con submódulos, en
   `/opt/discordia`. Root tiene que poder hacer `git pull` sin que le pidan credenciales.
2. Crear `/etc/discordia/nodes.env` (permisos 600) con `COMPOSE_PROFILES=<nodo>`, las IPs privadas de los
   otros nodos, el RDS (`DB_HOST`, `DB_USER`, `DB_PASSWORD`), un `<SERVICIO>_TAG` por servicio del nodo y
   los secretos de ese nodo (lista completa en `.env.example`). **Todos los secretos tienen que estar
   definidos**: los defaults del compose son solo para desarrollo. El CD necesita que cada `<SERVICIO>_TAG`
   exista, porque guarda el anterior para el rollback.
3. Verificar `/etc/discordia/node-name` (`edge`, `realtime` o `infra`; lo escribe cloud-init): el script de
   deploy rechaza una imagen de otro nodo.
4. Los paquetes de GHCR son privados: `docker login ghcr.io` como root, con un token de GitHub de solo
   lectura (`read:packages`).
5. Solo edge: `deploy/gateway.env` (de `gateway.env.example`) y el Origin Certificate de Cloudflare en
   `deploy/tls/` (`origin.pem`, `origin.key`).
6. Levantar en orden (infra → realtime → edge). En el servidor no se construye nada: se bajan las imágenes
   que publicó el CI de cada repo en GHCR:
   ```bash
   C="docker compose -f /opt/discordia/deploy/docker-compose.yml --env-file /etc/discordia/nodes.env"
   $C pull
   $C up -d --no-build
   ```

### A mano (emergencias)

Desde una sesión de SSM en el nodo:

```bash
sudo /opt/discordia/deploy/deploy-service.sh auth-service <sha de 40 caracteres>   # un servicio
sudo /opt/discordia/deploy/deploy-config.sh <sha de main>                           # la configuración
tail /var/log/discordia-deploy.log                                                  # qué se desplegó
```

Un deploy a mano queda pisado por el próximo push a `main` de ese repo. Para volver atrás de forma
duradera, hacer `git revert` en `main`: el CD despliega el revert. Si el `origin/main` del nodo está viejo,
primero `git fetch` y después `git checkout -B main origin/main`.

# Despliegue por nodo

Un solo compose (`deploy/docker-compose.yml`) para los tres nodos, igual en local y en producción.

| Nodo (profile) | Red | Servicios | Puertos publicados (para los otros nodos) |
|---|---|---|---|
| `edge` | `edge` | Kong + Redis, Auth (+worker), Server-Roles (+worker) | 443/8443 (Kong), 8001 (Auth internal, para Chat), 8002 (Server-Roles internal), 8100 (métricas de Kong, solo para infra) |
| `realtime` | `realtime` | Chat + Redis, Voice + Redis, LiveKit, Notification | 3000, 8082, 3001, 7880, 7881, 7882/udp |
| `infra` | `infra` | RabbitMQ, Payments, Prometheus, Grafana | 5672, 8003 |
| los tres | (default) | Node Exporter, cAdvisor (métricas de la máquina y de sus contenedores) | 9100, 9180 (solo para infra) |

**Base de datos:** ningún nodo corre Postgres. Los cuatro servicios con base relacional usan el RDS
(`DB_HOST`), cada uno con su base: `auth_db`, `server_roles_db` (edge), `notification_db` (realtime) y
`payments_db` (infra). En local, el profile `local` levanta un Postgres que hace de RDS en el 5432 del host
(crea las bases con `init-dbs.sql`) y los servicios le llegan por `host.docker.internal:5432`.

**Observabilidad:** Prometheus (infra) lee por IP:puerto los exportadores de los tres nodos y las métricas
de Kong (8100), según `observability/prometheus.yml.tmpl`. Grafana usa los dashboards del submódulo
`observability`, ordenados por nivel (Overview → Recursos → Comportamiento). Las reglas de alerta también
salen del submódulo (`observability/prometheus/rules/`) y se ven en Prometheus (*Alerts*) y en el Overview:
no hay Alertmanager.
Los paneles quedan en el host: Grafana en `http://localhost:3030` (usuario `admin`, contraseña
`GRAFANA_ADMIN_PASSWORD`; en local `dev-grafana`) y Prometheus en `http://localhost:9090` (*Status →
Targets*). En producción se entra por port forwarding de SSM:
`aws ssm start-session --target <id de infra> --document-name AWS-StartPortForwardingSession --parameters portNumber=3030,localPortNumber=3030`.

- En local los tres `*_HOST` son el mismo, así que Prometheus deja un solo target por exportador con
  `node=local` (si no, cada serie aparecería tres veces).
- Prometheus, Grafana, Node Exporter y cAdvisor llevan el label `discordia.deploy.optional`: si no quedan
  sanos, `deploy-config.sh` lo avisa en el log pero no revierte el nodo. Por eso la plantilla se valida
  antes, en el CI (`.github/workflows/validate-config.yml`, con `promtool`).

**Estado de la plataforma:** Notification (realtime) sondea los `/readyz` de todos los servicios a través de
Kong, por las rutas `/internal/readyz/*`, que solo aceptan IPs privadas. La URL de Kong es
`STATUS_GATEWAY_URL` (en local `https://host.docker.internal:8443`, en `.env.example`). Sin ella, esos
servicios quedan "Sin datos". El backoffice lo consume en `/api/v1/admin/status` (solo staff).

En producción, orden de puesta en marcha:

1. `terraform apply` con las reglas edge 443 desde realtime y edge 8100 desde infra.
2. `KONG_STATUS_BIND=0.0.0.0` en el `nodes.env` de edge y deploy del Gateway (con `/internal/readyz/*`).
3. Recién entonces, `STATUS_GATEWAY_URL=https://10.0.1.10:443` en el `nodes.env` de realtime.

Si se agrega antes, el estado público muestra una caída falsa.

**Métricas globales:** Notification arma `/api/v1/admin/metrics` (solo staff) pidiendo los conteos a
`/internal/metrics/*` de Chat (`CHAT_ENGINE_URL`, mismo nodo) y de Server-Roles (`CORE_SERVICE_URL`, el 8002
de edge). No hay variable nueva en `nodes.env`: salen de `EDGE_HOST`, y la regla edge 8002 desde realtime ya
existe. Si uno de los dos no responde, el dato sale vacío y el resto se muestra igual.

**Llamadas privadas:** Voice le pregunta a Chat si alguien puede llamar en una conversación y le pide que
avise por el inbox (`/internal/conversations/{id}/call-access`, `/internal/users/{id}/canonical` y
`/internal/inbox/events`), por `CHAT_SERVICE_URL` (mismo nodo, por nombre). No hay variable nueva en
`nodes.env` ni regla de Security Group: Voice y Chat están en realtime. Sin Chat, iniciar o aceptar una
llamada responde 503 y cortarla sigue andando. Va a `main` antes que los servicios: Voice nuevo sin la
variable cae al mismo default (`http://chat-engine-service:3000`), pero así queda explícito
([ADR 0015](../org-docs/docs/architecture/decisions/0015-llamadas-privadas.md)).

**Inbox interno (V9):** `POST /internal/inbox/events` de Chat exige el header `X-Internal-Token` igual a
`INTERNAL_API_TOKEN`; lo mandan Voice (avisos de llamadas) y Notification (avisos en vivo). Los tres están en
realtime y leen la misma variable del `nodes.env`. Si la variable está vacía, Chat no la exige: es el modo de
transición. Orden en producción:

1. Mergear a `main` el compose con `INTERNAL_API_TOKEN` (pasa vacío: nada cambia).
2. Desplegar Chat y Voice con soporte para el token (y Notification, cuando lo use).
3. Agregar `INTERNAL_API_TOKEN=<openssl rand -hex 32>` al `nodes.env` de realtime y recrear los tres
   contenedores (`deploy-config`, o `docker compose ... up -d --no-build chat-engine-service
   voice-signaling-service notification-service`). Verificar que una llamada privada sigue sonando.

Si se carga antes del paso 2, Voice recibe `401` y las llamadas privadas no avisan.

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

La API queda en `http://localhost:8000` (y con TLS autofirmado en `https://localhost:8443`).

**App mobile en un teléfono:** el 8000 se publica solo en `127.0.0.1`, así que el teléfono no le llega
(`Could not connect to the server`) y el 8443 no sirve porque iOS y Android rechazan el certificado
autofirmado. Con `GATEWAY_HTTP_BIND=0.0.0.0` en `deploy/.env` el 8000 queda en la red local y la app le
pega a la IP de esta máquina (la misma de Metro). Hay que recrear el Gateway
(`docker compose -f deploy/docker-compose.yml up -d gateway`) y tener el teléfono en la misma red. Solo en
redes de confianza: es la API sin TLS.

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
| `deploy-service.sh` | `deploy-service.sh <imagen> <sha>` | Baja la imagen, cambia `<SERVICIO>_TAG` en `nodes.env` y recrea solo los contenedores de ese repo (`--no-deps`). Rollback al tag anterior si no queda `healthy` en 120 s. Si queda, borra las imágenes que no usa ningún contenedor (`docker image prune -af`) |
| `deploy-config.sh` | `deploy-config.sh <sha>` | Lleva `/opt/discordia` a ese commit de `main`, corre `up -d` del nodo y recrea los contenedores cuyos archivos montados cambiaron. Rollback al commit anterior si el nodo no queda sano en 180 s (los servicios con `discordia.deploy.optional=true` solo generan un aviso) |

Los dos corren como root, toman el mismo lock (un deploy por vez en cada nodo) y aceptan solo el SHA
completo (40 caracteres). El CD los llama por SSM con los documentos `discordia-deploy-service` y
`discordia-deploy-config` (`infra/terraform/iam-cd.tf`): el rol `discordia-cd` no puede mandar ningún otro
comando a los nodos. Si cambia el comando que corre un documento, va por `terraform apply`, no por el CD.

El CD no aplica Terraform. Un puerto nuevo entre nodos necesita `terraform apply` antes del deploy: sin la
regla edge:8001, Chat no llega a Auth y los DMs fallan cerrados (503), aunque los canales sigan andando.

### Preparar un nodo nuevo (una sola vez)

1. Entrar por SSM (`terraform output ssm_connect`) y clonar el orquestador en `main`, con submódulos, en
   `/opt/discordia`. Root tiene que poder hacer `git pull` sin que le pidan credenciales.
2. Crear `/etc/discordia/nodes.env` (permisos 600) con `COMPOSE_PROFILES=<nodo>`, las IPs privadas de los
   otros nodos, el RDS (`DB_HOST`, `DB_USER`, `DB_PASSWORD`), un `<SERVICIO>_TAG` por servicio del nodo y
   los secretos de ese nodo (lista completa en `.env.example`). **Todos los secretos tienen que estar
   definidos**: los defaults del compose son solo para desarrollo. `RABBITMQ_*` y `LIVEKIT_*` no tienen
   default: si faltan, RabbitMQ, LiveKit y sus clientes no arrancan. El CD necesita que cada `<SERVICIO>_TAG`
   exista, porque guarda el anterior para el rollback.
3. Verificar `/etc/discordia/node-name` (`edge`, `realtime` o `infra`; lo escribe cloud-init): el script de
   deploy rechaza una imagen de otro nodo.
4. Los paquetes de GHCR son privados: `docker login ghcr.io` como root, con un token de GitHub de solo
   lectura (`read:packages`).
5. Solo edge: `deploy/gateway.env` (de `gateway.env.example`) y el Origin Certificate de Cloudflare en
   `deploy/tls/` (`origin.pem`, `origin.key`). Kong corre como el usuario `kong` de la imagen, no como root,
   así que `origin.key` lo tiene que poder leer ese UID. Cambió con Kong 3.9: la imagen pasó a Ubuntu 24.04,
   que ya trae un usuario `ubuntu` con UID 1000. Con permiso para los dos, también anda un rollback a una
   imagen anterior (ver el UID con `docker run --rm --entrypoint id ghcr.io/discordia-g12/gateway:<sha>`):
   ```bash
   sudo setfacl -m u:1000:r,u:1001:r /opt/discordia/deploy/tls/origin.key
   ```
   Sin esto, Kong no arranca (`cannot load certificate key ... Permission denied`) y el deploy vuelve al tag
   anterior.
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

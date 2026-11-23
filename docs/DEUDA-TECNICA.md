# Deuda técnica

Lo que queda pendiente a propósito, con el motivo y qué haría falta para resolverlo. Agrupado por tema.
Al cerrar un ítem, borrarlo de acá (y mencionarlo en el PR).

---

## Orden planteado

| Prioridad | Ítems | Por qué |
|-----------|-------|---------|
| **Alta** | R2 | Una dependencia sin fijar ya tiró un servicio |
| **Media** | C1, V2, D1, D2, I1, M1, M6, V9 | Permisos que no se actualizan en vivo, usuario maestro compartido, TLS sin validar, estado de Terraform en una sola máquina, puertos internos sin autenticación, identidad partida por alias |
| **Baja** | R1, P1, P2, V3, V4, V5, V6, V7, V8, C3, C4, C5, I2, M2, M3, M4, M5, M7 | Payments todavía no tiene funcionalidad, mejoras de diseño, limpieza después del deploy, o solo hacen falta si el sistema crece |

---

## Plan de la prioridad alta

### R2 — Fijar versiones de dependencias

Orden: Server-Roles (es el que corre en producción con todo en `>=`), después las imágenes de Node, al final
Payments. Cada paso es un PR por repo, y el CI de cada uno ya construye la imagen y corre los tests.

1. **Server-Roles.** Sacar las versiones que hoy funcionan en producción de la imagen desplegada:
   `docker run --rm ghcr.io/discordia-g12/server-roles-service:<tag del nodes.env> pip freeze`. Fijar con
   `==` las dependencias directas de `requirements.txt` (mismo formato que Auth). Mover `pytest` y `httpx`
   a `requirements-dev.txt`, que ya incluye `-r requirements.txt` y es lo que instala el CI.
2. **Imágenes de Node** (Chat, Voice, Notification):
   - Usar `npm ci` en todas las etapas (`npm ci --omit=dev` en la final). `npm install` puede resolver
     versiones distintas a las del `package-lock.json`; `npm ci` instala exactamente lo del lock o falla.
   - Voice: pasar a dos etapas como Chat (build con dependencias de desarrollo; imagen final solo con
     `dist/` y las de producción). Su CI corre los tests **dentro de la imagen** (`docker compose run`), así
     que hay que pasarlo a `actions/setup-node` como Chat, o correr los tests sobre la etapa de build
     (`target: build`).
   - Las imágenes ya están en `node:26-alpine`. Falta que el CI pruebe con la misma versión:
     `.nvmrc` con `26` y `node-version-file: .nvmrc`. Notification ya lo tiene; Chat sigue con `"20"` fijo.
3. **Payments.** Igual que Server-Roles. No tiene funcionalidad todavía, pero el cambio es chico y es el
   repo que ya se rompió por esto.
4. **Imágenes de terceros.** Fijar `nginx:alpine` (WebApp) a una versión (`nginx:1.xx-alpine`) y
   `rabbitmq:3-management-alpine` a `3.13-management-alpine`. La rama 3.x de RabbitMQ ya no tiene soporte
   comunitario, pero pasar a 4.x es un cambio aparte (hay que habilitar los feature flags antes de
   actualizar). Verificar hasta cuándo tiene soporte Kong 3.4.
5. **Fastify 4 en Voice.** No tiene soporte desde junio de 2025 (Chat y Notification ya están en Fastify 5).
   Migrar a Fastify 5 (y `@fastify/websocket` 11) es un cambio de versión mayor: hacerlo en un PR aparte, con
   los tests como red. En Notification el único cambio de comportamiento fue de timing: `ready()` resuelve
   unos ticks más tarde, y los tests que suponían que la primera ronda seguía en curso tuvieron que cambiar.
6. **Dependabot** en cada repo (`.github/dependabot.yml`): ecosistemas `pip` o `npm`, `docker` y
   `github-actions`, semanal, con las actualizaciones *minor* y *patch* agrupadas en un solo PR. Así las
   versiones se actualizan con CI en vez de cambiar solas en el próximo build.

Verificación: el CI de cada repo en verde y levantar `deploy/docker-compose.yml` con el profile `local`
(login, crear servidor, chat, voz).

---

## Chat (Chat-Engine-Service)

| # | Qué falta | Detalle |
|---|-----------|---------|
| C1 | **Aplicar en vivo los cambios de rol** | `EventConsumer` solo se suscribe a `member.*` y solo maneja `banned`, `kicked`, `left`, `muted` y `unmuted`. Si a alguien le sacan un rol (`member.role_removed`) o un rol pierde `SEND_MESSAGES` (`role.permissions_updated`, `role.deleted`), la sesión abierta sigue con `canSend: true` hasta que reconecta. Para `member.role_*` alcanza con volver a llamar a `/internal/channels/{id}/access` para las sesiones de ese usuario en ese servidor y mandar `PERMISSIONS_UPDATED` con el `canSend` nuevo (y cerrar la sesión si ya no puede ver el canal). Para `role.*` el evento no trae `user_id` (hoy `handleEvent` lo descarta): o se rechequean todas las sesiones del servidor, o Server-Roles agrega la lista de usuarios afectados al payload. Lo mismo pasa con `channel.deleted`: las sesiones de un canal borrado quedan abiertas. |
| C3 | Más de una instancia del chat | Hoy hay una sola. Si se agregan más hacen falta dos cosas: una cola por instancia (`RABBITMQ_QUEUE` distinto, idealmente `exclusive`/`auto-delete` con el nombre del contenedor) porque `chat_engine_events` es compartida y cada evento le llega a una sola instancia, y el pub/sub de Redis para repartir los mensajes, porque hoy el broadcast es solo a los sockets de la misma instancia (`SessionManager` en memoria; el cliente Redis ya está creado pero no se usa para eso). |
| C5 | Fijados sin auditoría | Fijar y desfijar en un servidor (`PUT`/`DELETE /channels/:id/messages/:mid/pin`, ADR-05 de Chat) no deja rastro en el audit log, a diferencia del borrado por un moderador. Publicar `message.pinned` / `message.unpinned` como `message.deleted_by_moderator` y sumarlos a `AUDIT_ROUTING_KEYS`, al mapper y a las acciones de Notification-Audit-Metrics. |
| C4 | Límite del historial | `limit` viene de la query sin tope (`?limit=1000000` le pide todo el canal a Atlas M0) y `getMissedMessages` no tiene límite. Poner un máximo (ej. 100) y validar `before` / `last_message_id_seen` como ObjectId. |

## Mensajes directos (Auth, Chat, Server-Roles y clientes)

Contexto: [ADR 0011](../org-docs/docs/architecture/decisions/0011-mensajes-directos.md).

| # | Qué falta | Detalle |
|---|-----------|---------|
| M1 | **Rate limit de solicitudes de amistad** | `POST /users/me/friend-requests` solo tiene el límite general de Kong: se puede usar para mandar solicitudes en masa. Agregar un límite por usuario en Kong o en Auth. También `/internal` de Auth y de Server-Roles: no tienen autenticación, los protege solo el Security Group, y el 8001 y el 8002 exponen toda la API, que confía en `X-User-Id`. Ver P1. |
| M2 | Solicitudes en tiempo real | Las solicitudes de amistad se piden cada 30 s y al volver a la app. Quien recibe una puede tardar hasta 30 s en verla, y lo mismo vale para un chat al que no se podía escribir: a quien desbloquean, el composer le vuelve con ese polling. Publicar el cambio por `inbox:<usuario>`, para lo que Auth tendría que avisarle a Chat. |
| M3 | Push a mobile | Con la app cerrada no llega nada: el mensaje se ve al volver. Hace falta guardar tokens de dispositivo y un sender (Expo Push o APNs + FCM), probablemente en Notification. |
| M4 | `202` vs `201` deja inferir un bloqueo | Una solicitud a quien te bloqueó responde `202` y no aparece en `outgoing`; a alguien que no bloqueó, por username, `201`. En la interfaz se ven igual, pero a nivel API se puede deducir. Para taparlo, Auth tendría que guardar una solicitud "fantasma" que solo vea quien la mandó. |
| M5 | Adjuntos en el primer mensaje | `POST /channels/:id/attachments` exige un id `dm-…`, que no existe antes del primer mensaje, y los clientes no ofrecen adjuntar en un chat nuevo. `POST /conversations` ya acepta `attachments`: falta dónde subirlos antes de tener conversación (por ejemplo, un prefijo por usuario). |
| M6 | Servidores en común y baneos con alias | Core guarda el `sub` crudo en `server_members`, `server_bans` y `servers.owner_id`, y nadie usa `/users/resolve-identity`. Con login federado, una misma persona puede tener membresías bajo dos ids: `GET /servers/mutual` da falsos negativos (nunca filtra de más) y un baneo bajo un id no alcanza al otro. Los clientes piden servidores en común con el id con el que se abrió el perfil, para que un alias no los pierda. Resolverlo en Kong o migrar Core al id canónico. |
| M7 | Tests de `tests/test_deps.py` en Auth | 12 de 13 fallan con `AttributeError`: llaman a `get_authenticated_identity` directo, sin `x_user_role`, y reciben el `Header(...)` por defecto en lugar de un string. Vienen de la suspensión de usuarios, no de los DMs. Es el test el que hay que corregir: el rol llega bien por HTTP. |

## Voz (Voice-Signaling-Session-Service)

| # | Qué falta | Detalle |
|---|-----------|---------|
| V2 | El mute no aplica a la voz | `can-connect` no mira `ServerMute` ni `SPEAK`, y el token siempre lleva `canPublish: true`. Un muteado, o alguien sin `SPEAK`, puede hablar. Devolver los permisos en la respuesta de `can-connect` y usar `canPublish` según `SPEAK` y mute. El consumidor de eventos de Voice ya existe (`modules/voice/events.ts`): sumar los bindings `member.muted` / `member.unmuted` y cambiar el permiso en vivo con `roomService.updateParticipant`. |
| V3 | Llamadas abiertas antes del deploy del consumidor | Voice guarda de qué servidor es cada llamada recién desde `/join` con la versión nueva (`user:{id}:voice_server`). A quien ya estaba en una llamada al desplegar, un ban no lo saca hasta que vuelva a entrar. Se resuelve solo en cuanto todos vuelven a unirse; no hace falta migrar nada. |
| V4 | Evento que falla al aplicarse | Si Redis o LiveKit fallan mientras se procesa un ban, el evento se descarta (no se reencola para no entrar en loop). El bloqueo suele quedar guardado igual (es lo primero que se escribe), pero el usuario sigue en la llamada actual. Si pasa seguido, reencolar con un límite de reintentos (header `x-death` con una dead-letter queue). |

Llamadas privadas (#50): contexto en [ADR 0015](../org-docs/docs/architecture/decisions/0015-llamadas-privadas.md)
y en el ADR-04 de Voice-Signaling-Session-Service.

| # | Qué falta | Detalle |
|---|-----------|---------|
| V5 | Timer del timbre en memoria | El `setTimeout` de 30 s vive en la instancia que atendió el inicio. Si Voice se reinicia mientras suena (un deploy), nadie publica `CALL_ENDED` con `missed`: el TTL de 45 s de `call:<id>` libera el ocupado y el cliente da la llamada por perdida a los `expiresAt + 10 s`. Con más de una instancia de Voice pasa lo mismo. Para escalar, un barrido periódico de llamadas vencidas con el mismo compare-and-set (y mover también la presencia, ADR-02 de Voice). |
| V6 | Un bloqueo no corta una llamada activa | `call-access` se consulta al iniciar y al aceptar. Si uno bloquea al otro durante la llamada, sigue hasta que alguien corte. Para cortarla, Auth tendría que avisar el bloqueo (hoy no publica eventos de relaciones, ver M2) y Voice terminarla con `unavailable`. |
| V7 | Sin aviso con la app cerrada | La llamada suena solo si el inbox está conectado. Es el mismo push que falta para los DM (M3), con un requisito más: en mobile, una llamada entrante necesita notificación de alta prioridad (CallKit / ConnectionService) para sonar con el teléfono bloqueado. |
| V8 | La llamada no queda en el chat | Ni "llamada perdida" ni la duración aparecen en la conversación: quien no estaba conectado no se entera de que lo llamaron. Voice podría pedirle a Chat que guarde un mensaje de sistema al terminar (otro endpoint interno), con cuidado de no contarlo como no leído de quien llamó. |
| V9 | `POST /internal/inbox/events` de Chat: secreto opcional | Exige `X-Internal-Token` (`INTERNAL_API_TOKEN`, compartido con Voice y Notification), pero solo si la variable está cargada: sin ella, quien llegue al 3000 de realtime sin pasar por Kong puede publicar un `CALL_*` o `NOTIFICATION_*` en el inbox de cualquiera. Falta cargarla en el `nodes.env` de realtime y después volverla obligatoria (que Chat no arranque sin ella). El resto de `/internal` (M1, P1) sigue protegido solo por red: el mismo helper (`requireInternalToken`) sirve para cerrarlo. |
Un startup_failure en main no avisa a nadie, y el deploy de Voice estuvo frenado 6 días sin que se notara. Lo sumaría a docs/DEUDA-TECNICA.md: avisar cuando falla el CD de main (notificaciones de Actions o un check periódico que compare el SHA desplegado con el de main).

## Permisos entre servicios

| # | Qué falta | Detalle |
|---|-----------|---------|
| P1 | Foto de permisos por eventos (eliminar `can-send` / `can-connect`) | Hoy Chat y Voice llaman por HTTP a Server-Roles (edge, puerto 8002 abierto a realtime) cada vez que se abre un chat o alguien entra a una llamada. No suma un punto de falla (si edge cae, Kong también), pero acopla los servicios, agrega latencia y deja un puerto abierto entre nodos. La idea es que Chat y Voice armen su propia copia de miembros, roles, overrides, bans y mutes a partir de los eventos y calculen el permiso localmente. Es el cambio más grande de la lista y depende de C1 (los eventos tienen que traer todo lo necesario, y hace falta una carga inicial). El cálculo de permisos ya es una función pura, sin base de datos (`effective_channel_permissions` en `Server-Roles-Core-Service/app/core/permissions.py`): Chat y Voice pueden replicarla tal cual. Mientras tanto, los endpoints `/internal/*` no tienen autenticación: cualquiera que llegue al 8002 puede preguntar los permisos de cualquier usuario. |
| P2 | Borrar `can-send` | Chat ya usa `/internal/channels/{id}/access`. `can-send` queda (marcado como deprecado) solo para que una versión vieja de Chat siga andando durante el deploy. Cuando Chat nuevo esté en producción, borrar el endpoint y sus tests (`tests/test_internal_can_send.py` y el caso de `test_server_bans.py` que lo usa). |

## Datos

| # | Qué falta | Detalle |
|---|-----------|---------|
| D1 | Un usuario de base por servicio | Los cuatro servicios usan el usuario maestro `discordia_admin` (`DB_USER` igual en los tres nodos). Si se filtra la contraseña de uno, se pueden leer y borrar las cuatro bases, y el usuario maestro también puede cambiar la configuración del RDS. Crear `auth_svc`, `server_roles_svc`, `notification_svc`, `payments_svc` con permisos solo sobre su base (dueños de su schema para que `alembic` pueda migrar) y dejar `discordia_admin` solo para administración. Requiere variables por servicio en el compose (hoy es una sola `DB_USER`). |
| D2 | TLS con `verify-full` | Notification se conecta con `sslmode=no-verify`: cifra, pero acepta cualquier certificado. Bajar el bundle de CA de RDS (`global-bundle.pem`) en la imagen y usar `sslmode=verify-full&sslrootcert=...`. Auth, Server-Roles (asyncpg) y Payments (psycopg2) tampoco validan el certificado: usan el default `prefer`. Conviene aplicar lo mismo a los cuatro. |

## Repos, imágenes y dependencias

| # | Qué falta | Detalle |
|---|-----------|---------|
| R1 | `--reload` en los Dockerfiles de Payments y Server-Roles | El `CMD` de los dos es `uvicorn ... --reload` (modo desarrollo: un proceso extra que vigila los archivos y reinicia el servicio si cambian). En Server-Roles el compose de `deploy/` lo pisa; en Payments no, así que corre así en producción. Payments todavía no tiene funcionalidad, por eso es prioridad baja, pero conviene sacarlo de los dos Dockerfiles antes de que tenga tráfico. |
| R2 | **Fijar versiones de dependencias** | Auth tiene todo fijado con `==`. Server-Roles tiene todo con `>=` (incluido `sqlalchemy>=2.0`, el mismo caso que rompió Payments) e instala `pytest` y `httpx` en la imagen de producción. Payments no fija casi nada. En Node hay `package-lock.json`, pero los Dockerfiles usan `npm install`. Las imágenes de Chat, Voice y Notification ya usan Node 26, pero el CI de Chat prueba con Node 20, y Voice sigue en Fastify 4, que ya no tiene soporte. `nginx:alpine` y `rabbitmq:3-management-alpine` no fijan versión. Plan arriba. |

## Infraestructura

| # | Qué falta | Detalle |
|---|-----------|---------|
| I1 | Estado de Terraform en una sola máquina | `terraform.tfstate` es el registro de qué recursos de AWS y Cloudflare creó Terraform (IDs de la VPC, las EC2, el bucket, los Security Groups). Hoy está solo en la máquina de quien hizo el `apply` (está en `.gitignore`, bien, porque puede tener datos sensibles). Si se pierde, Terraform no sabe que esos recursos existen: el próximo `apply` intenta crearlos de nuevo y falla, o hay que importarlos uno por uno. Si otra persona aplica desde su máquina, parte de un estado vacío o viejo. `versions.tf` ya eligió HCP Terraform (bloque `cloud` comentado), falta activarlo: crear la organización `discordia-g12` y el workspace `discordia-prod` en app.terraform.io (plan Free), poner el workspace en *Execution mode: Local* (el `plan` y el `apply` siguen corriendo en tu máquina con tu perfil de AWS; HCP solo guarda el estado y lo bloquea mientras alguien aplica), descomentar el bloque, `terraform login`, `terraform init` (pregunta si migrar el estado local: sí), verificar que `terraform plan` no muestre cambios y recién ahí borrar el `terraform.tfstate` local. Actualizar el comentario de `versions.tf`, que todavía habla de tres cuentas. |
| I2 | Tamaño del nodo realtime | Realtime es una `t3.micro` (1 GB) con Chat, Voice, LiveKit, Notification y dos Redis. Si LiveKit se queda sin memoria o CPU con varias llamadas, evaluar `t3.small` solo para ese nodo (`instance_type` es una sola variable para los tres: habría que separarla). Mirar el dashboard de cAdvisor antes de decidir. Lo mismo vale para infra: sus límites suman 1024 MB en 1 GB (RabbitMQ, Payments, Prometheus y Grafana), así que no hay lugar para Alertmanager (O2) ni para darle más memoria a Prometheus. |

## Observabilidad

Contexto: ADR-O1 a ADR-O4 en `observability/docs/` y §10 de `ARQUITECTURA.md`.

| # | Qué falta | Detalle |
|---|-----------|---------|
| O1 | `/metrics` propio en cada servicio | El nivel 2 (comportamiento) solo tiene el RED del gateway (plugin `prometheus` de Kong) y RabbitMQ. Ningún servicio expone `/metrics`: no hay latencia interna, ni estado del outbox, ni dependencias de `/readyz` (`discordia_dependency_up`), ni runtime de Node (`nodejs_*`). Sumar `prom-client` (Chat, Voice, Notification) y `prometheus-fastapi-instrumentator` o `prometheus_client` (Auth, Server-Roles, Payments) con las convenciones de `observability/docs/observability-conventions.md` (rutas como plantilla, sin IDs en labels). Para scrapearlos desde infra: un puerto por servicio y su regla de Security Group, o pasar a Alloy por nodo (ADR-O3). |
| O2 | Las alertas no avisan a nadie | Las reglas evalúan en Prometheus y se ven en *Alerts* y en el Overview, pero no hay Alertmanager ni canal (ADR-O4). Si se agranda infra (I2) o se pasa a un nodo de monitoreo (ADR-O1), sumar Alertmanager con un receptor (Discord/Slack/mail) y la alarma `Watchdog`. Mientras tanto, mirar el Overview después de cada deploy. |
| O3 | Métricas de negocio | Notification arma el estado de la plataforma y los incidentes (historia 74, con migraciones y `audit_logs`, ADR-03 del servicio). Faltan las métricas de negocio 70–73 (consumidor de eventos de RabbitMQ y tablas agregadas por día, ADR-O2). Las rutas `/api/v1/audit` y `/api/v1/metrics` de Kong todavía dan 404. |

---

## Imágenes (avatares e íconos de servidor)

Contexto: [ADR-003](../Auth-User-Service/docs/ADR-003-Avatares.md). Todas las imágenes viven en el bucket S3
`discordia-g12-media` (`infra/terraform/storage.tf`), bajo `avatars/` y `server-icons/`.

### Clientes

La web y mobile suben el ícono al crear un servidor, lo cambian o lo quitan desde Ajustes del servidor →
Resumen, y suben el avatar desde el perfil. Todo va como archivo, con las mismas funciones de core (en iOS y
Android el transporte es `XMLHttpRequest`, registrado con `configureClient({ sendForm })`), y la interfaz usa
la URL que devuelve la API. No queda nada pendiente de imágenes en los clientes.

### Backend e infraestructura

| # | Qué falta | Detalle |
|---|-----------|---------|
| B1 | **Servir las imágenes a través de Cloudflare** | Hoy las URLs apuntan directo al bucket (`https://discordia-g12-media.s3.us-east-1.amazonaws.com/...`): cada vista es un GET que S3 cobra (requests + tráfico de salida) y el nombre del bucket queda expuesto. La idea es usar el mismo Cloudflare que ya administra `discordia.lol`: un subdominio proxied (ej. `media.discordia.lol`) delante del bucket, para que Cloudflare cachee las imágenes (son inmutables, `Cache-Control: immutable`) y S3 casi no reciba tráfico. Para que S3 acepte el pedido, el bucket tiene que llamarse igual que el host (`media.discordia.lol`, con website hosting) o hay que poner un Worker que reescriba el `Host`. En el código alcanza con cambiar `S3_PUBLIC_BASE_URL`. **Ojo:** las URLs ya guardadas en la base quedan con el dominio viejo y `delete_image` solo borra las del dominio actual: hay que migrarlas (un `UPDATE` con `replace`) en el mismo cambio. |
| B2 | Subida directa con *presigned POST* | Hoy el archivo pasa por Kong y por el servicio. Con URLs firmadas el cliente subiría directo a S3, pero se pierde la validación real del contenido y la normalización a WebP (habría que hacerlas después, por ejemplo con un Lambda). Vale la pena solo si aparecen archivos más grandes (adjuntos de chat). |
| B4 | Eliminar servidor (y borrar sus imágenes) | La web y mobile llaman a `DELETE /api/v1/servers/{id}` (`deleteServer` en core), pero Server-Roles **no tiene ese endpoint**: eliminar un servidor hoy falla. Al agregarlo (solo el dueño), borrar el ícono con `storage.delete_image` después del commit y emitir `server.deleted` por outbox. Lo mismo para el avatar cuando exista el borrado de cuenta en Auth. |
| B5 | Restringir `avatar_url` en el alta y en `PATCH /profile` | `POST /api/v1/users/me` acepta cualquier URL (≤ 500 caracteres): se puede usar para tracking o contenido externo. `PATCH /api/v1/users/me/profile` también acepta `avatar_url`, **sin límite de largo**: una URL de más de 500 caracteres (por ejemplo un data URL, que es lo que mandaba la web antes) choca con la columna y da 500. Sacar `avatar_url` de `PATCH /profile` (el avatar se cambia solo con `PATCH /profile/avatar`) y, en el alta, restringirlo al bucket propio y a los dominios de Auth0 (`s.gravatar.com`, `lh3.googleusercontent.com`, `*.auth0.com`, etc.), o copiar la `picture` de Auth0 al bucket. |
| B6 | Objetos huérfanos | Si un `delete_object` falla, el archivo queda en el bucket sin que nadie lo use (se loguea `s3_delete_failed`, no se reintenta). Con imágenes de ~20 KB el costo es despreciable; si crece, un job que compare el bucket contra la base. |
| B7 | Límite de tamaño en Kong | `request-size-limiting` está en 50 MB global. Los servicios rechazan más de 5 MB, pero recién después de leer todo el archivo en memoria (hasta 50 MB por pedido en contenedores de 256 MB). Bajar el límite a ~6 MB en las rutas de subida. |
| B8 | Desarrollo local sin AWS | En local hacen falta claves (`AUTH_AWS_ACCESS_KEY_ID` / `SERVER_ROLES_AWS_ACCESS_KEY_ID` y sus secretos en `deploy/.env`), idealmente de un usuario IAM de desarrollo con un bucket aparte, o la subida responde 503. Alternativa: MinIO en el compose y un `S3_ENDPOINT_URL` en la config de los dos servicios. |
| B9 | Módulo de storage duplicado | `Auth-User-Service/app/services/storage_service.py` y `Server-Roles-Core-Service/app/services/storage.py` (igual con la validación de imagen) son copias. Si se agrega un tercer servicio con imágenes, conviene extraerlo a un paquete compartido. |
| B10 | Imágenes animadas | GIF no se acepta; un WebP animado se guarda con su primer cuadro. Si se quieren avatares animados (¿feature Premium?), hay que conservar los cuadros y ajustar el límite de tamaño. |
| B11 | Rotación de las access keys | Cada servicio usa claves de larga duración de su usuario IAM (`discordia-auth-media`, `discordia-server-roles-media`), cargadas en el `nodes.env`. No hay rotación automática: rotarlas a mano (`terraform output media_access_key_commands`, actualizar el `nodes.env`, reiniciar el servicio y borrar la clave vieja con `aws iam delete-access-key`). Si se pasa a un gestor de secretos (SSM Parameter Store, Secrets Manager), que sea por servicio y no por nodo. |

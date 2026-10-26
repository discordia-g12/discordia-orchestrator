# Deuda técnica

Lo que queda pendiente a propósito, con el motivo y qué haría falta para resolverlo. Agrupado por tema.
Al cerrar un ítem, borrarlo de acá (y mencionarlo en el PR).

---

## Orden planteado

| Prioridad | Ítems | Por qué |
|-----------|-------|---------|
| **Alta** | R2, V1, C2 | Una dependencia sin fijar ya tiró un servicio; un usuario baneado sigue en la llamada; un muteado no puede leer el chat |
| **Media** | C1, V2, D1, D2, L1, L2, I1 | Permisos que no se actualizan en vivo, usuario maestro compartido, TLS sin validar, archivos de ejemplo desactualizados, estado de Terraform en una sola máquina |
| **Baja** | R1, P1, C3, C4, M1, I2 | Payments todavía no tiene funcionalidad, mejoras de diseño, o solo hacen falta si el sistema crece |

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
   - Node 20 → 22, igual que el WebApp: `FROM node:22-alpine`, `.nvmrc` con `22` y
     `node-version-file: .nvmrc` en el CI (Chat y Notification hoy tienen `"20"` fijo).
3. **Payments.** Igual que Server-Roles. No tiene funcionalidad todavía, pero el cambio es chico y es el
   repo que ya se rompió por esto.
4. **Imágenes de terceros.** Fijar `nginx:alpine` (WebApp) a una versión (`nginx:1.xx-alpine`) y
   `rabbitmq:3-management-alpine` a `3.13-management-alpine`. La rama 3.x de RabbitMQ ya no tiene soporte
   comunitario, pero pasar a 4.x es un cambio aparte (hay que habilitar los feature flags antes de
   actualizar). Verificar hasta cuándo tiene soporte Kong 3.4.
5. **Fastify 4 en Voice y Notification.** No tiene soporte desde junio de 2025 (Chat ya está en Fastify 5).
   Migrar a Fastify 5 (y `@fastify/websocket` 11 en Voice) es un cambio de versión mayor: hacerlo en un PR
   aparte, después de fijar todo lo demás y con los tests como red.
6. **Dependabot** en cada repo (`.github/dependabot.yml`): ecosistemas `pip` o `npm`, `docker` y
   `github-actions`, semanal, con las actualizaciones *minor* y *patch* agrupadas en un solo PR. Así las
   versiones se actualizan con CI en vez de cambiar solas en el próximo build.

Verificación: el CI de cada repo en verde y levantar `deploy/docker-compose.yml` con el profile `local`
(login, crear servidor, chat, voz).

### V1 — Sacar de la llamada al baneado o expulsado

Server-Roles no cambia: ya emite `member.banned`, `member.kicked` y `member.left` con `server_id` y `user_id`.

1. **Guardar a qué servidor pertenece la llamada.** Voice guarda en Redis solo el canal
   (`user:{id}:voice_channel`), y `checkCanConnect` descarta el `server_id` que devuelve `can-connect`.
   Devolverlo y guardarlo al unirse (`user:{id}:voice_server`), y borrarlo en `/leave` y en el webhook. Sin
   esto, un ban del servidor A sacaría al usuario de una llamada del servidor B.
2. **Consumidor de RabbitMQ.** Agregar `amqplib` y copiar el `EventConsumer` de Chat, que ya tiene
   reconexión con backoff y tests. Cola propia y durable (`voice_signaling_events`) con los bindings
   `member.banned`, `member.kicked` y `member.left`. Agregar `RABBITMQ_URL` a Voice en
   `deploy/docker-compose.yml` (el Security Group ya abre 5672 desde realtime). `/readyz` informa el estado
   de RabbitMQ sin marcarse no-ready, igual que Chat.
3. **Handler.** Si `user:{id}:voice_server` coincide con el `server_id` del evento:
   `roomService.removeParticipant(canal, userId)` (ignorar el error si ya no está), limpiar Redis
   (`removeFromChannel`, que ya existe) y publicar la presencia del canal.
4. **Que no pueda volver a entrar con el token viejo.**
   - `ttl` corto en el `AccessToken` (por ejemplo 10 minutos). LiveKit renueva el token de quien ya está
     conectado, así que las llamadas largas no se cortan.
   - En el webhook `participant_joined`: si `user:{id}:voice_channel` no es esa sala (no pasó por `/join`),
     `removeParticipant`. Esto cubre el token todavía vigente o renovado de alguien que ya fue sacado.
5. **Cliente.** Hoy cualquier corte muestra "Se perdió la conexión con el canal de voz". Usar el
   `DisconnectReason` de LiveKit (`PARTICIPANT_REMOVED`) para mostrar que lo sacaron. Entra en el refactor
   del WebApp y no bloquea el backend.
6. **Tests.** Handler con Redis y `RoomServiceClient` simulados (incluido el caso de otro servidor),
   consumidor con la conexión falsa que usan los tests de Chat, y el chequeo del webhook. A mano: dos
   usuarios en una llamada, banear a uno, ver que sale, e intentar volver a entrar.

Deja armado lo necesario para V2 (`member.muted` / `unmuted` → `updateParticipant` con `canPublish`).

### C2 — Separar el permiso de ver del de escribir

Resuelve también el vencimiento del mute: hoy se agenda con un `setTimeout` en memoria, y un mute que vence
después de un reinicio del chat no se levantaría en una sesión abierta con `canSend: false` (paso 4).

1. **Server-Roles: una sola función de permisos.** Extraer el cálculo de permisos efectivos (dueño,
   `ADMINISTRATOR`, roles, overrides de rol y de miembro), hoy copiado en `can-send` y `can-connect`, a una
   función que devuelva el bitmask del usuario en el canal. Los dos endpoints la usan sin cambiar sus
   respuestas. Sirve también para P1.
2. **Server-Roles: endpoint nuevo** `GET /internal/channels/{id}/access?user_id=`:
   - 404 si el canal no existe.
   - 403 si no es miembro, está baneado o no tiene `VIEW_CHANNELS`.
   - 200 con `{ server_id, can_send, muted_until }`: `can_send` es `SEND_MESSAGES` y sin mute vigente;
     `muted_until` es el `expires_at` del mute (`null` si no hay o si es indefinido).

   Es una sola llamada en lugar de dos. `@everyone` ya trae `VIEW_CHANNELS`, así que los miembros actuales no
   pierden acceso: solo se bloquea a quien tenga un rol u override que lo niegue. `can-send` sigue hasta que
   Chat deje de usarlo y después se borra.
3. **Chat: guard.** `channelAccessGuard` llama a `/access`, responde 403 solo si no puede ver y guarda
   `canSend` y `mutedUntil` en el request. El historial (`GET /channels/:id/messages`) queda accesible para un
   muteado.
4. **Chat: WebSocket.** Registrar la sesión con el `canSend` de la respuesta (hoy siempre `true`) y mandar
   al abrir un primer `{ type: "PERMISSIONS_UPDATED", canSend, channelId }`, así el cliente sabe desde el
   principio si puede escribir. Si viene `mutedUntil`, agendar la expiración con el mismo timer que
   `member.muted` (`scheduleMuteExpiry`, hoy privado): así un mute que vence después de un reinicio del chat
   se levanta igual.
5. **Cliente** (WebApp y mobile, en el refactor): hoy `PERMISSIONS_UPDATED` se ignora y el muteado recién se
   entera cuando falla el envío. Deshabilitar el input con un aviso ("Estás silenciado") según ese mensaje.
   Además, `chatSocket` reconecta siempre: con los códigos 4002 / 4003 (expulsado o baneado) tiene que dejar
   de reintentar.
6. **Orden de despliegue:** Server-Roles primero (el endpoint nuevo no rompe nada), después Chat, después
   borrar `can-send`.
7. **Tests.** Server-Roles: dueño, admin, sin `VIEW_CHANNELS`, override que niega `VIEW_CHANNELS`, muteado
   temporal e indefinido, baneado, no miembro. Chat: un muteado abre el socket y lee el historial pero no
   puede enviar; al vencer el mute puede enviar; sin `VIEW_CHANNELS`, 403.

---

## Chat (Chat-Engine-Service)

| # | Qué falta | Detalle |
|---|-----------|---------|
| C1 | **Aplicar en vivo los cambios de rol** | `EventConsumer` solo se suscribe a `member.*` y solo maneja `banned`, `kicked`, `left`, `muted` y `unmuted`. Si a alguien le sacan un rol (`member.role_removed`) o un rol pierde `SEND_MESSAGES` (`role.permissions_updated`, `role.deleted`), la sesión abierta sigue con `canSend: true` hasta que reconecta. Para `member.role_*` alcanza con volver a llamar a `/access` (C2) para las sesiones de ese usuario en ese servidor y mandar `PERMISSIONS_UPDATED`. Para `role.*` el evento no trae `user_id` (hoy `handleEvent` lo descarta): o se rechequean todas las sesiones del servidor, o Server-Roles agrega la lista de usuarios afectados al payload. Lo mismo pasa con `channel.deleted`: las sesiones de un canal borrado quedan abiertas. Conviene hacerlo después de C2. |
| C2 | **Separar el permiso de ver del de escribir** | `channelAccessGuard` usa `can-send` para abrir el WebSocket **y** para el historial. `can-send` responde 403 si el usuario está muteado o no tiene `SEND_MESSAGES`, así que un muteado no puede ni leer el canal. Además `VIEW_CHANNELS` no se chequea en ningún lado. Plan arriba. |
| C3 | Más de una instancia del chat | Hoy hay una sola. Si se agregan más hacen falta dos cosas: una cola por instancia (`RABBITMQ_QUEUE` distinto, idealmente `exclusive`/`auto-delete` con el nombre del contenedor) porque `chat_engine_events` es compartida y cada evento le llega a una sola instancia, y el pub/sub de Redis para repartir los mensajes, porque hoy el broadcast es solo a los sockets de la misma instancia (`SessionManager` en memoria; el cliente Redis ya está creado pero no se usa para eso). |
| C4 | Límite del historial | `limit` viene de la query sin tope (`?limit=1000000` le pide todo el canal a Atlas M0) y `getMissedMessages` no tiene límite. Poner un máximo (ej. 100) y validar `before` / `last_message_id_seen` como ObjectId. |

## Voz (Voice-Signaling-Session-Service)

| # | Qué falta | Detalle |
|---|-----------|---------|
| V1 | **Sacar de la llamada al baneado o expulsado** | Voice no consume RabbitMQ: un usuario baneado o expulsado sigue hablando hasta que corta. Además el token de LiveKit se emite sin `ttl` (el default del SDK es de horas), así que con ese token se puede volver a entrar sin pasar por `can-connect`. Plan arriba. |
| V2 | El mute no aplica a la voz | `can-connect` no mira `ServerMute` ni `SPEAK`, y el token siempre lleva `canPublish: true`. Un muteado, o alguien sin `SPEAK`, puede hablar. Devolver los permisos en la respuesta de `can-connect` y usar `canPublish` según `SPEAK` y mute; con V1 andando, `member.muted` / `unmuted` pueden cambiar el permiso en vivo con `updateParticipant`. |

## Permisos entre servicios

| # | Qué falta | Detalle |
|---|-----------|---------|
| P1 | Foto de permisos por eventos (eliminar `can-send` / `can-connect`) | Hoy Chat y Voice llaman por HTTP a Server-Roles (edge, puerto 8002 abierto a realtime) cada vez que se abre un chat o alguien entra a una llamada. No suma un punto de falla (si edge cae, Kong también), pero acopla los servicios, agrega latencia y deja un puerto abierto entre nodos. La idea es que Chat y Voice armen su propia copia de miembros, roles, overrides, bans y mutes a partir de los eventos y calculen el permiso localmente. Es el cambio más grande de la lista y depende de C1, C2 y V1 (los eventos tienen que traer todo lo necesario, y hace falta una carga inicial). Mientras tanto, los endpoints `/internal/*` no tienen autenticación: cualquiera que llegue al 8002 puede preguntar los permisos de cualquier usuario. |

## Datos

| # | Qué falta | Detalle |
|---|-----------|---------|
| D1 | Un usuario de base por servicio | Los cuatro servicios usan el usuario maestro `discordia_admin` (`DB_USER` igual en los tres nodos). Si se filtra la contraseña de uno, se pueden leer y borrar las cuatro bases, y el usuario maestro también puede cambiar la configuración del RDS. Crear `auth_svc`, `server_roles_svc`, `notification_svc`, `payments_svc` con permisos solo sobre su base (dueños de su schema para que `alembic` pueda migrar) y dejar `discordia_admin` solo para administración. Requiere variables por servicio en el compose (hoy es una sola `DB_USER`). |
| D2 | TLS con `verify-full` | Notification se conecta con `sslmode=no-verify`: cifra, pero acepta cualquier certificado. Bajar el bundle de CA de RDS (`global-bundle.pem`) en la imagen y usar `sslmode=verify-full&sslrootcert=...`. Auth, Server-Roles (asyncpg) y Payments (psycopg2) tampoco validan el certificado: usan el default `prefer`. Conviene aplicar lo mismo a los cuatro. |

## Repos, imágenes y dependencias

| # | Qué falta | Detalle |
|---|-----------|---------|
| R1 | `--reload` en los Dockerfiles de Payments y Server-Roles | El `CMD` de los dos es `uvicorn ... --reload` (modo desarrollo: un proceso extra que vigila los archivos y reinicia el servicio si cambian). En Server-Roles el compose de `deploy/` lo pisa; en Payments no, así que corre así en producción. Payments todavía no tiene funcionalidad, por eso es prioridad baja, pero conviene sacarlo de los dos Dockerfiles antes de que tenga tráfico. |
| R2 | **Fijar versiones de dependencias** | Auth tiene todo fijado con `==`. Server-Roles tiene todo con `>=` (incluido `sqlalchemy>=2.0`, el mismo caso que rompió Payments) e instala `pytest` y `httpx` en la imagen de producción. Payments no fija casi nada. En Node hay `package-lock.json`, pero los Dockerfiles usan `npm install`. Chat, Voice y Notification siguen en Node 20, que ya no tiene soporte, y Voice y Notification en Fastify 4, que tampoco. `nginx:alpine` y `rabbitmq:3-management-alpine` no fijan versión. Plan arriba. |

## Desarrollo local

| # | Qué falta | Detalle |
|---|-----------|---------|
| L1 | Compose de la raíz apunta al RDS | Los servicios del `docker-compose.yml` de la raíz usan `DATABASE_HOST=${RDS_HOST}` sin default, y el `.env.example` trae el endpoint del RDS: quien copie el ejemplo y tenga la contraseña desarrolla contra la base de producción, y sin `RDS_HOST` el servicio arranca con el host vacío (aunque el compose levanta un `postgres` y espera a que esté sano). Usar `${RDS_HOST:-postgres}` (y `RDS_USER`/`RDS_PASSWORD` con los mismos defaults que el contenedor) y sacar el RDS del ejemplo. Además el contenedor usa `postgres:16` y el RDS es 18 (el compose de `deploy/` ya usa 18). Evaluar si el compose de la raíz sigue haciendo falta: `deploy/docker-compose.yml` con el profile `local` hace lo mismo, salvo el WebApp. |
| L2 | `.env.example` desactualizados | El `.env.example` de la raíz tiene un `LIVEKIT_API_SECRET` real (no es el de producción, pero es un secreto commiteado: reemplazarlo por un placeholder) y `VITE_API_URL` / `VITE_WS_URL` apuntan a la EC2 del monolito. `apps/mobile/.env.example` también apunta a esa EC2. `deploy/.env.example` todavía pide `CLOUDINARY_*`, que ya no se usa (las imágenes van a S3). |

## Infraestructura

| # | Qué falta | Detalle |
|---|-----------|---------|
| I1 | Estado de Terraform en una sola máquina | `terraform.tfstate` es el registro de qué recursos de AWS y Cloudflare creó Terraform (IDs de la VPC, las EC2, el bucket, los Security Groups). Hoy está solo en la máquina de quien hizo el `apply` (está en `.gitignore`, bien, porque puede tener datos sensibles). Si se pierde, Terraform no sabe que esos recursos existen: el próximo `apply` intenta crearlos de nuevo y falla, o hay que importarlos uno por uno. Si otra persona aplica desde su máquina, parte de un estado vacío o viejo. `versions.tf` ya eligió HCP Terraform (bloque `cloud` comentado), falta activarlo: crear la organización `discordia-g12` y el workspace `discordia-prod` en app.terraform.io (plan Free), poner el workspace en *Execution mode: Local* (el `plan` y el `apply` siguen corriendo en tu máquina con tu perfil de AWS; HCP solo guarda el estado y lo bloquea mientras alguien aplica), descomentar el bloque, `terraform login`, `terraform init` (pregunta si migrar el estado local: sí), verificar que `terraform plan` no muestre cambios y recién ahí borrar el `terraform.tfstate` local. Actualizar el comentario de `versions.tf`, que todavía habla de tres cuentas. |
| I2 | Tamaño del nodo realtime | Realtime es una `t3.micro` (1 GB) con Chat, Voice, LiveKit, Notification y dos Redis. Si LiveKit se queda sin memoria o CPU con varias llamadas, evaluar `t3.small` solo para ese nodo (`instance_type` es una sola variable para los tres: habría que separarla). Mirar el dashboard de cAdvisor antes de decidir. |

## Mobile

| # | Qué falta | Detalle |
|---|-----------|---------|
| M1 | Sacar `usesCleartextTraffic` | `apps/mobile/app.json` permite HTTP en Android. Hace falta para desarrollo (`http://10.0.2.2:8000`), pero en un build de release deja que la app hable sin cifrar si alguna URL quedó en `http://`. Ahora que todo va por `https://api.discordia.lol`, activarlo solo en el perfil de desarrollo (por ejemplo con `app.config.ts` según el perfil de EAS). |

---

## Imágenes (avatares e íconos de servidor)

Contexto: [ADR-003](../Auth-User-Service/docs/ADR-003-Avatares.md). Todas las imágenes viven en el bucket S3
`discordia-g12-media` (`infra/terraform/storage.tf`), bajo `avatars/` y `server-icons/`.

### Frontend (en espera del refactor del WebApp)

| # | Qué falta | Detalle |
|---|-----------|---------|
| F1 | **El ícono de servidor no llega como archivo** | `CreateServerModal` lee la imagen con `FileReader.readAsDataURL` y pasa el data-URL (un string) como `icon`. `createServer` lo agrega al `FormData` como texto, y el backend espera un archivo (`UploadFile`): crear un servidor con ícono falla. Hay que guardar el `File` del `<input type="file">` y mandar ese objeto. El data-URL sirve solo para la vista previa. |
| F2 | Íconos predefinidos (`PRESET_ICONS`) | Hoy son strings vacíos. Si se quieren íconos predefinidos, o se mandan como archivo igual que uno subido, o se agrega un campo aparte en el backend. |
| F3 | **Subir avatar desde el perfil** | El endpoint existe (`PATCH /api/v1/users/me/profile/avatar`, `multipart/form-data`, campo `file`) pero el WebApp nunca lo llama. El avatar que se ve es la `picture` de Auth0 que se manda como URL en el alta. |
| F4 | Usar la URL de la respuesta | Cada subida genera una URL nueva y la anterior se borra del bucket. Después de cambiar avatar o ícono, el estado local tiene que tomar la `avatar_url` / `icon_url` que devuelve la API; si se queda con la vieja, la imagen se rompe. |
| F5 | Mostrar errores de subida | 400 / 422 (formato, más de 5 MB, más de 4096×4096 px) y 503 (storage caído) en los modales de perfil y de creación de servidor. |
| F6 | Ícono en la vista previa de invitación | `GET /api/v1/invites/{code}` ahora devuelve `server_icon` (antes venía siempre vacío por un bug). `JoinServerModal` ya lo lee: verificar que se muestre. |

### Backend e infraestructura

| # | Qué falta | Detalle |
|---|-----------|---------|
| B1 | **Servir las imágenes a través de Cloudflare** | Hoy las URLs apuntan directo al bucket (`https://discordia-g12-media.s3.us-east-1.amazonaws.com/...`): cada vista es un GET que S3 cobra (requests + tráfico de salida) y el nombre del bucket queda expuesto. La idea es usar el mismo Cloudflare que ya administra `discordia.lol`: un subdominio proxied (ej. `media.discordia.lol`) delante del bucket, para que Cloudflare cachee las imágenes (son inmutables, `Cache-Control: immutable`) y S3 casi no reciba tráfico. Para que S3 acepte el pedido, el bucket tiene que llamarse igual que el host (`media.discordia.lol`, con website hosting) o hay que poner un Worker que reescriba el `Host`. En el código alcanza con cambiar `S3_PUBLIC_BASE_URL`. **Ojo:** las URLs ya guardadas en la base quedan con el dominio viejo y `delete_image` solo borra las del dominio actual: hay que migrarlas (un `UPDATE` con `replace`) en el mismo cambio. |
| B2 | Subida directa con *presigned POST* | Hoy el archivo pasa por Kong y por el servicio. Con URLs firmadas el cliente subiría directo a S3, pero se pierde la validación real del contenido y la normalización a WebP (habría que hacerlas después, por ejemplo con un Lambda). Vale la pena solo si aparecen archivos más grandes (adjuntos de chat). |
| B3 | Cambiar o quitar el ícono de un servidor existente | Solo se puede poner al crear. Falta `PATCH /servers/{id}/icon` (y `DELETE`) con chequeo de permisos (`MANAGE_SERVER` o dueño), borrar el ícono anterior y emitir `server.updated` por outbox. |
| B4 | Borrar imágenes al eliminar servidor o cuenta | Todavía no hay endpoints de borrado de servidor ni de cuenta. Cuando existan, tienen que llamar a `delete_image` con el ícono y el avatar. |
| B5 | Restringir el dominio de `avatar_url` en el alta | `POST /api/v1/users/me` acepta cualquier URL (≤ 500 caracteres): se puede usar para tracking o contenido externo. Restringir al bucket propio y a los dominios de Auth0 (`s.gravatar.com`, `lh3.googleusercontent.com`, `*.auth0.com`, etc.), o copiar la `picture` de Auth0 al bucket en el alta. |
| B6 | Objetos huérfanos | Si un `delete_object` falla, el archivo queda en el bucket sin que nadie lo use (se loguea `s3_delete_failed`, no se reintenta). Con imágenes de ~20 KB el costo es despreciable; si crece, un job que compare el bucket contra la base. |
| B7 | Límite de tamaño en Kong | `request-size-limiting` está en 50 MB global. Los servicios rechazan más de 5 MB, pero recién después de leer todo el archivo en memoria (hasta 50 MB por pedido en contenedores de 256 MB). Bajar el límite a ~6 MB en las rutas de subida. |
| B8 | Desarrollo local sin AWS | En local hacen falta claves (`AUTH_AWS_ACCESS_KEY_ID` / `SERVER_ROLES_AWS_ACCESS_KEY_ID` y sus secretos en el `.env` de la raíz), idealmente de un usuario IAM de desarrollo con un bucket aparte, o la subida responde 503. Alternativa: MinIO en el compose y un `S3_ENDPOINT_URL` en la config de los dos servicios. |
| B9 | Módulo de storage duplicado | `Auth-User-Service/app/services/storage_service.py` y `Server-Roles-Core-Service/app/services/storage.py` (igual con la validación de imagen) son copias. Si se agrega un tercer servicio con imágenes, conviene extraerlo a un paquete compartido. |
| B10 | Imágenes animadas | GIF no se acepta; un WebP animado se guarda con su primer cuadro. Si se quieren avatares animados (¿feature Premium?), hay que conservar los cuadros y ajustar el límite de tamaño. |
| B11 | Rotación de las access keys | Cada servicio usa claves de larga duración de su usuario IAM (`discordia-auth-media`, `discordia-server-roles-media`), cargadas en el `nodes.env`. No hay rotación automática: rotarlas a mano (`terraform output media_access_key_commands`, actualizar el `nodes.env`, reiniciar el servicio y borrar la clave vieja con `aws iam delete-access-key`). Si se pasa a un gestor de secretos (SSM Parameter Store, Secrets Manager), que sea por servicio y no por nodo. |

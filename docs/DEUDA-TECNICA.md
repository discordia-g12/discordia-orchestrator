# Deuda técnica

Lo que queda pendiente a propósito, con el motivo y qué haría falta para resolverlo. Agrupado por tema.
Al cerrar un ítem, borrarlo de acá (y mencionarlo en el PR).

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
| B8 | Desarrollo local sin AWS | En local hace falta un usuario IAM de desarrollo (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) o la subida responde 503. Alternativa: MinIO en el compose y un `S3_ENDPOINT_URL` en la config de los dos servicios. |
| B9 | Módulo de storage duplicado | `Auth-User-Service/app/services/storage_service.py` y `Server-Roles-Core-Service/app/services/storage.py` (igual con la validación de imagen) son copias. Si se agrega un tercer servicio con imágenes, conviene extraerlo a un paquete compartido. |
| B10 | Imágenes animadas | GIF no se acepta; un WebP animado se guarda con su primer cuadro. Si se quieren avatares animados (¿feature Premium?), hay que conservar los cuadros y ajustar el límite de tamaño. |
| B11 | Acceso de los contenedores a la metadata de EC2 | Para que Auth y Server-Roles lean las credenciales del rol, el nodo edge permite 2 saltos en IMDSv2 (`imds_hop_limit = 2`). Eso habilita a *todos* los contenedores del nodo (Kong, Redis) a pedir esas credenciales. El rol solo puede escribir y borrar en los dos prefijos de imágenes, así que el impacto es acotado. La alternativa más estricta es un usuario IAM con access keys solo para esos dos servicios. |

# LiveKit (voz)

Servidor [LiveKit](https://livekit.io) self-hosted que maneja el audio de los canales de voz. Corre desde
`docker-compose.yml` como servicio `livekit` (contenedor `discordia-livekit`), con la config de
[`livekit.yaml`](livekit.yaml). No hace falta ninguna cuenta de LiveKit.

## Cómo encaja

```
Browser ──(REST, vía Gateway)──> voice-signaling-service ──> devuelve { token, url }
Browser ──(WebSocket + WebRTC, directo)──> livekit:7880 / 7881 tcp / 7882 udp
```

El audio **no pasa por el Gateway**: el browser se conecta directo a LiveKit con el token que firma el
voice-service. Por eso LiveKit y el voice-service tienen que compartir `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET`.

| Puerto | Uso |
|--------|-----|
| `7880/tcp` | API HTTP + señalización WebSocket |
| `7881/tcp` | Media WebRTC por TCP (fallback) |
| `7882/udp` | Media WebRTC por UDP |

## Variables

Se definen en el `.env` de la raíz del orchestrator (ver `.env.example`). Si no se definen, el compose usa
defaults de desarrollo.

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | `devkey` / `devsecret_change_me_min_32_chars_long` | Credenciales compartidas con el voice-service. Para generar un par propio: `docker run --rm livekit/livekit-server:v1.13.7 generate-keys` |
| `LIVEKIT_NODE_IP` | `127.0.0.1` | IP que LiveKit anuncia a los clientes para la media. En un deploy, la IP pública del host. |
| `LIVEKIT_PUBLIC_URL` | `ws://localhost:7880` | URL que el voice-service le devuelve al cliente. En un deploy, `wss://<dominio>` (el micrófono requiere HTTPS fuera de localhost). |

## Cómo probar que funciona

Todos los comandos se corren desde la raíz del orchestrator.

**1. Levantar y chequear**

```bash
docker compose up -d livekit
curl localhost:7880                      # → OK
```

**2. Cargar las credenciales en la terminal**

```bash
# Si tenés LIVEKIT_API_KEY / LIVEKIT_API_SECRET en el .env:
export $(grep -E '^LIVEKIT_API_(KEY|SECRET)=' .env | xargs)
# Si no, usá los defaults:
# export LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=devsecret_change_me_min_32_chars_long
```

**3. Verificar las credenciales** (tiene que imprimir la room; un `401` significa que no coinciden)

```bash
docker run --rm --network discordia-net livekit/livekit-cli room create \
  --url http://livekit:7880 --api-key $LIVEKIT_API_KEY --api-secret $LIVEKIT_API_SECRET prueba
```

**4. Probar audio real con el cliente de prueba**

Generar un token por usuario:

```bash
docker run --rm livekit/livekit-cli token create --api-key $LIVEKIT_API_KEY --api-secret $LIVEKIT_API_SECRET \
  --join --room prueba --identity user1 --valid-for 24h | grep "Access token"
docker run --rm livekit/livekit-cli token create --api-key $LIVEKIT_API_KEY --api-secret $LIVEKIT_API_SECRET \
  --join --room prueba --identity user2 --valid-for 24h | grep "Access token"
```

Servir [`test-client.html`](test-client.html) (queda corriendo en esa terminal):

```bash
python3 -m http.server 8090 -d livekit
```

Abrir `http://localhost:8090/test-client.html` en dos pestañas, pegar un token distinto en cada una y tocar
**Conectar + micrófono**. Tienen que aparecer los dos participantes y escucharse entre sí (usar auriculares
para evitar acople).

> Usar este cliente y no `meet.livekit.io`: los browsers bloquean que una página pública se conecte a
> `localhost`, y la conexión queda colgada en "connecting" sin llegar a LiveKit.

## Problemas comunes

- **`401 Unauthorized`**: las keys del comando no son las del contenedor. Ver con qué arrancó:
  `docker inspect discordia-livekit --format '{{range .Config.Env}}{{println .}}{{end}}' | grep LIVEKIT_KEYS`
- **Se conectan pero no se escuchan**: casi siempre es UDP. Revisar que `docker compose ps livekit` muestre
  `7882/udp` y que ningún firewall local lo bloquee.
- **Queda en "connecting"**: mirar `docker compose logs livekit`. Si no aparece ningún intento de conexión,
  el problema está en el browser o la URL, no en el servidor.

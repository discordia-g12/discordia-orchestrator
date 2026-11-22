# LiveKit (voz)

Servidor [LiveKit](https://livekit.io) self-hosted que maneja el audio de los canales de voz. Corre desde
`deploy/docker-compose.yml` como servicio `livekit` (profile `realtime`, contenedor
`discordia-nodes-livekit-1`), con la config de [`livekit.yaml`](livekit.yaml). No hace falta ninguna cuenta
de LiveKit.

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

En local van en `deploy/.env` (copia de `deploy/.env.example`, que trae las de desarrollo); en producción, en
el `nodes.env` del nodo realtime.

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | Ninguno: sin ellas LiveKit no arranca. En `deploy/.env.example`: `devkey` / `devsecret_change_me_min_32_chars_long` | Credenciales compartidas con el voice-service. Para generar un par propio: `docker run --rm livekit/livekit-server:v1.13.7 generate-keys` |
| `LIVEKIT_NODE_IP` | `127.0.0.1` | IP que LiveKit anuncia a los clientes para la media. En producción, la Elastic IP del nodo realtime. |
| `LIVEKIT_PUBLIC_URL` | `ws://localhost:8000/livekit` | URL que el voice-service le devuelve al cliente (señalización por Kong). En producción, `wss://api.discordia.lol/livekit`. |

## Cómo probar que funciona

Todos los comandos se corren desde la raíz del orchestrator.

**1. Levantar y chequear**

```bash
docker compose -f deploy/docker-compose.yml up -d livekit
curl localhost:7880                      # → OK
```

**2. Cargar las credenciales en la terminal**

```bash
export $(grep -E '^LIVEKIT_API_(KEY|SECRET)=' deploy/.env | xargs)
```

**3. Verificar las credenciales** (tiene que imprimir la room; un `401` significa que no coinciden)

```bash
docker run --rm --network discordia-nodes_realtime livekit/livekit-cli room create \
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
  `docker inspect discordia-nodes-livekit-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep LIVEKIT_KEYS`
- **Se conectan pero no se escuchan**: casi siempre es UDP. Revisar que
  `docker compose -f deploy/docker-compose.yml ps livekit` muestre `7882/udp` y que ningún firewall local lo
  bloquee.
- **Queda en "connecting"**: mirar `docker compose -f deploy/docker-compose.yml logs livekit`. Si no aparece
  ningún intento de conexión,
  el problema está en el browser o la URL, no en el servidor.

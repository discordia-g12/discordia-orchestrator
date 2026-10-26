#!/bin/bash
# Despliega en este nodo la imagen de un servicio que publicó el CI en GHCR, y vuelve a la anterior si no
# queda healthy. Lo corre el workflow de deploy por SSM (como root), pero también sirve a mano:
#
#   sudo /opt/discordia/deploy/deploy-service.sh auth-service <sha de 40 caracteres>
#
# Pasos: valida, baja la imagen, cambia <SERVICIO>_TAG en nodes.env, recrea solo los contenedores de ese
# repo (--no-deps) y espera a que todos queden healthy. Si alguno no llega, restaura el tag anterior.
# Cada deploy queda en /var/log/discordia-deploy.log. Ver docs/TODO-CD.md (paso 2).
set -euo pipefail

COMPOSE_FILE=/opt/discordia/deploy/docker-compose.yml
ENV_FILE=/etc/discordia/nodes.env
NODE_FILE=/etc/discordia/node-name
LOG_FILE=/var/log/discordia-deploy.log
LOCK_FILE=/var/lock/discordia-deploy.lock
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}" # segundos

# Imagen → "nodo variable-del-tag servicios de compose" (Auth y Server-Roles también reinician su worker)
declare -A SERVICES=(
  [gateway]="edge GATEWAY_TAG gateway"
  [auth-service]="edge AUTH_SERVICE_TAG auth-service auth-outbox-worker"
  [server-roles-service]="edge SERVER_ROLES_TAG server-roles-service server-roles-outbox-worker"
  [chat-engine-service]="realtime CHAT_ENGINE_TAG chat-engine-service"
  [voice-signaling-service]="realtime VOICE_SIGNALING_TAG voice-signaling-service"
  [notification-service]="realtime NOTIFICATION_TAG notification-service"
  [payments-service]="infra PAYMENTS_TAG payments-service"
)

# Por SSM puede no estar HOME, y docker lo necesita para encontrar el login de ghcr.io (/root/.docker)
export HOME="${HOME:-/root}"

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
log() { echo "[deploy] $*"; }
fail() { echo "[deploy] ERROR: $*" >&2; exit 1; }

set_tag() { sed -i "s|^${TAG_VAR}=.*|${TAG_VAR}=$1|" "$ENV_FILE"; }

record() { # resultado
  echo "$(date -u +%FT%TZ) node=$NODE image=$IMAGE from=${PREV_TAG:-none} to=$SHA result=$1" >> "$LOG_FILE"
}

# 0 si todos los contenedores quedan healthy antes del timeout
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) svc id status pending
  while ((SECONDS < deadline)); do
    pending=""
    for svc in "${COMPOSE_SERVICES[@]}"; do
      id="$(dc ps -q "$svc")"
      status="$( [ -n "$id" ] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" || echo missing)"
      [ "$status" = healthy ] || pending+=" $svc=$status"
    done
    [ -z "$pending" ] && return 0
    sleep 5
  done
  log "no quedaron healthy en ${HEALTH_TIMEOUT}s:$pending"
  return 1
}

show_logs() {
  local svc
  for svc in "${COMPOSE_SERVICES[@]}"; do
    log "últimas líneas de $svc:"
    dc logs --no-color --tail 40 "$svc" || true
  done
}

main() {
  [ "$(id -u)" -eq 0 ] || fail "hay que correrlo como root"
  [ $# -eq 2 ] || fail "uso: $0 <imagen> <sha>"
  IMAGE="$1"
  SHA="$2"

  # El formato primero: [[ -v ]] expande el subíndice, y un "$(...)" en el argumento se ejecutaría
  [[ "$IMAGE" =~ ^[a-z-]+$ ]] && [[ -v "SERVICES[$IMAGE]" ]] || fail "imagen desconocida: $IMAGE (válidas: ${!SERVICES[*]})"
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "el SHA tiene que ser el commit completo (40 caracteres hex): $SHA"

  read -r EXPECTED_NODE TAG_VAR COMPOSE_SERVICES_STR <<< "${SERVICES[$IMAGE]}"
  read -r -a COMPOSE_SERVICES <<< "$COMPOSE_SERVICES_STR"
  NODE="$(cat "$NODE_FILE")"
  [ "$NODE" = "$EXPECTED_NODE" ] || fail "$IMAGE va en el nodo $EXPECTED_NODE y este es $NODE"

  # Un deploy por vez en el nodo: dos servicios del mismo nodo editan el mismo nodes.env
  exec 9> "$LOCK_FILE"
  flock -w 300 9 || fail "hay otro deploy en curso en este nodo"

  PREV_TAG="$(sed -n "s/^${TAG_VAR}=//p" "$ENV_FILE")"
  [ -n "$PREV_TAG" ] || fail "$TAG_VAR no está en $ENV_FILE: sin tag anterior no hay a qué volver"
  log "$IMAGE en $NODE: ${PREV_TAG} → ${SHA}"

  # El compose actualizado. Si falla (red, credenciales), se despliega con el que ya está: la configuración
  # tiene su propio deploy (paso 5 de TODO-CD.md).
  git -c safe.directory=/opt/discordia -C /opt/discordia pull --ff-only --quiet \
    || log "aviso: no se pudo actualizar /opt/discordia, sigo con el compose actual"

  # Se baja la imagen antes de tocar nodes.env: si no existe en GHCR, no cambia nada
  env "$TAG_VAR=$SHA" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull --quiet "${COMPOSE_SERVICES[@]}" \
    || { record pull-failed; fail "no se pudo bajar la imagen $IMAGE:$SHA"; }

  set_tag "$SHA"
  dc up -d --no-build --no-deps "${COMPOSE_SERVICES[@]}"

  if wait_healthy; then
    record ok
    log "listo: $IMAGE:$SHA healthy"
    return 0
  fi

  show_logs
  log "rollback a $PREV_TAG"
  set_tag "$PREV_TAG"
  dc up -d --no-build --no-deps "${COMPOSE_SERVICES[@]}"
  if wait_healthy; then
    record rolled-back
    fail "$IMAGE:$SHA no quedó healthy; volvió a $PREV_TAG"
  fi
  record rollback-failed
  fail "$IMAGE:$SHA no quedó healthy y $PREV_TAG tampoco: revisar el nodo a mano"
}

# Todo adentro de main: el git pull puede reescribir este archivo mientras corre, y bash ya leyó la función entera
main "$@"
exit

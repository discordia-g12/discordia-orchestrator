#!/bin/bash
# Despliega en este nodo la configuración del orquestador (compose, livekit/, rabbitmq/, observability) de un
# commit de main, y vuelve al commit anterior si el nodo no queda sano. Lo corre el workflow deploy-config por
# SSM (como root), pero también sirve a mano:
#
#   sudo /opt/discordia/deploy/deploy-config.sh <sha de 40 caracteres de main>
#
# Pasos: lleva /opt/discordia a ese commit (fast-forward), actualiza el submódulo observability, corre
# "up -d" de todo el nodo (Compose recrea solo los contenedores cuya definición cambió), recrea a mano los que
# montan un archivo que cambió (Compose no se entera de eso) y espera a que todo el nodo quede sano. Si no queda,
# vuelve al commit anterior. Comparte lock y log con deploy-service.sh. Ver docs/TODO-CD.md (paso 5).
set -euo pipefail

REPO=/opt/discordia
COMPOSE_FILE=$REPO/deploy/docker-compose.yml
ENV_FILE=/etc/discordia/nodes.env
NODE_FILE=/etc/discordia/node-name
LOG_FILE=/var/log/discordia-deploy.log
LOCK_FILE=/var/lock/discordia-deploy.lock
# Último commit cuya configuración se aplicó. No alcanza con HEAD: el deploy de un servicio también hace
# git pull, y puede traer un livekit.yaml nuevo sin recrear livekit.
STATE_FILE=/etc/discordia/config-sha
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}" # segundos: puede reiniciar varios contenedores del nodo

# Archivos montados en un contenedor → servicio que hay que recrear si cambian. Si un servicio no es de este
# nodo, se ignora (nombrarlo en "up" activaría su profile y lo levantaría acá).
MOUNTS=(
  "livekit/ livekit"
  "rabbitmq/ rabbitmq"
  "deploy/observability/ prometheus"
  "observability grafana" # el submódulo: dashboards y provisioning
)

# Por SSM puede no estar HOME, y docker y git lo necesitan (login de ghcr.io, credenciales de github.com)
export HOME="${HOME:-/root}"

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
g() { git -c safe.directory=$REPO -c safe.directory=$REPO/observability -C "$REPO" "$@"; }
log() { echo "[config] $*"; }
fail() { echo "[config] ERROR: $*" >&2; exit 1; }

record() { # resultado
  echo "$(date -u +%FT%TZ) node=$NODE image=config from=${BASE:0:7} to=${SHA:0:7} result=$1" >> "$LOG_FILE"
}

# Lleva el repo y el submódulo a un commit. Los "|| return": adentro de un if o un ||, set -e no corta.
checkout() {
  g reset --quiet --hard "$1" || return 1
  g submodule update --init --quiet observability || return 1
}

# Servicios a recrear: los de MOUNTS cuyo archivo cambió entre BASE y SHA, y que corren en este nodo
mounted_changes() {
  local entry path svc changed
  changed="$(g diff --name-only "$BASE" "$SHA")"
  for entry in "${MOUNTS[@]}"; do
    read -r path svc <<< "$entry"
    grep -q "^$path" <<< "$changed" && [[ " ${NODE_SERVICES[*]} " == *" $svc "* ]] && echo "$svc"
  done
  return 0
}

apply() { # servicios a recrear
  dc up -d --no-build || return 1
  if [ $# -gt 0 ]; then
    log "recreo por archivos montados: $*"
    dc up -d --no-build --no-deps --force-recreate "$@" || return 1
  fi
}

# 0 si todos los servicios del nodo quedan healthy (o running, los que no tienen healthcheck)
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) svc id status pending
  while ((SECONDS < deadline)); do
    pending=""
    for svc in "${NODE_SERVICES[@]}"; do
      id="$(dc ps -a -q "$svc")"
      status="$( [ -n "$id" ] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" || echo missing)"
      [[ "$status" =~ ^(healthy|running)$ ]] || pending+=" $svc=$status"
    done
    [ -z "$pending" ] && return 0
    sleep 5
  done
  log "no quedaron sanos en ${HEALTH_TIMEOUT}s:$pending"
  return 1
}

main() {
  [ "$(id -u)" -eq 0 ] || fail "hay que correrlo como root"
  [ $# -eq 1 ] || fail "uso: $0 <sha>"
  SHA="$1"
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "el SHA tiene que ser el commit completo (40 caracteres hex): $SHA"
  NODE="$(cat "$NODE_FILE")"

  # Un deploy por vez en el nodo, incluidos los de servicios: todos usan el mismo repo y nodes.env
  exec 9> "$LOCK_FILE"
  flock -w 300 9 || fail "hay otro deploy en curso en este nodo"

  [ "$(g branch --show-current)" = main ] || fail "$REPO no está en main"
  [ -z "$(g status --porcelain --untracked-files=no)" ] || fail "$REPO tiene cambios locales: revisar a mano"
  g fetch --quiet origin main
  g merge-base --is-ancestor "$SHA" origin/main || fail "$SHA no está en main"

  HEAD_BEFORE="$(g rev-parse HEAD)"
  # Si el nodo ya está en ese commit o más adelante (el deploy de un servicio hizo pull), se aplica lo que tiene
  if g merge-base --is-ancestor "$SHA" "$HEAD_BEFORE"; then
    SHA="$HEAD_BEFORE"
  else
    g merge-base --is-ancestor "$HEAD_BEFORE" "$SHA" \
      || fail "el nodo está en ${HEAD_BEFORE:0:7}, que no es ancestro de ${SHA:0:7}"
  fi
  # La base es el último commit aplicado. Si no hay (primer deploy) o no es ancestro, el commit actual del nodo.
  BASE="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if ! { [[ "$BASE" =~ ^[0-9a-f]{40}$ ]] && g merge-base --is-ancestor "$BASE" "$HEAD_BEFORE" 2>/dev/null; }; then
    BASE="$HEAD_BEFORE"
  fi
  log "$NODE: ${BASE:0:7} → ${SHA:0:7}"

  checkout "$SHA" || { checkout "$HEAD_BEFORE" || true; record git-failed; fail "no se pudo llevar $REPO a ${SHA:0:7}"; }

  # Los servicios de los profiles de este nodo (COMPOSE_PROFILES de nodes.env), con el compose nuevo
  mapfile -t NODE_SERVICES < <(dc config --services)
  mapfile -t RECREATE < <(mounted_changes)

  if apply "${RECREATE[@]}" && wait_healthy; then
    echo "$SHA" > "$STATE_FILE"
    record ok
    log "listo: $NODE en ${SHA:0:7}"
    return 0
  fi

  dc ps -a || true
  log "rollback a ${BASE:0:7}"
  checkout "$BASE" || { record rollback-failed; fail "no se pudo volver $REPO a ${BASE:0:7}: revisar el nodo a mano"; }
  mapfile -t NODE_SERVICES < <(dc config --services)
  if apply "${RECREATE[@]}" && wait_healthy; then
    record rolled-back
    fail "${SHA:0:7} no dejó el nodo sano; volvió a ${BASE:0:7}. Hasta que se corrija en main, el próximo git pull lo vuelve a traer"
  fi
  record rollback-failed
  fail "${SHA:0:7} no dejó el nodo sano y ${BASE:0:7} tampoco: revisar el nodo a mano"
}

# Todo adentro de main: el reset puede reescribir este archivo mientras corre, y bash ya leyó la función entera
main "$@"
exit

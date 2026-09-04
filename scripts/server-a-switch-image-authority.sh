#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_IMAGE="${TARGET_IMAGE:-ghcr.io/appolon1908-hue/websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd}"
LEGACY_IMAGE="${LEGACY_IMAGE:-ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd}"
COMPOSE_FILE="${COMPOSE_FILE:-/home/codestra-admin/releases/middleware-69723c25a27e2a64cf55539c7d6df362a33579a4/websocket_gateway/compose.yaml}"
PROJECT_NAME="${PROJECT_NAME:-codestra-websocket-gateway}"
SERVICE="${SERVICE:-gateway}"
CONTAINER_NAME="${CONTAINER_NAME:-codestra-websocket-gateway-gateway-1}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8080/healthz}"
READY_URL="${READY_URL:-http://127.0.0.1:8080/readyz}"
STATE_ROOT="${STATE_ROOT:-./websocket-authority-cutover}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"

usage() {
  cat <<'USAGE'
Repoint Server A from the Codestra-SRL registry path to the byte-identical
appolon1908-hue mirror. The legacy reference remains the rollback authority.

Required preparation:
  1. Run on Server A (65.109.65.169).
  2. Authenticate Docker to ghcr.io for appolon1908-hue package reads.
  3. Confirm evidence/legacy-image-mirror.json reports verification=PASS.
  4. Run from a directory where STATE_ROOT can be written.

Environment overrides:
  COMPOSE_FILE, PROJECT_NAME, SERVICE, CONTAINER_NAME, TARGET_IMAGE,
  LEGACY_IMAGE, HEALTH_URL, READY_URL, STATE_ROOT, TIMEOUT_SECONDS

Commands:
  server-a-switch-image-authority.sh status
  server-a-switch-image-authority.sh apply
  server-a-switch-image-authority.sh rollback
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"
}

expected_digest() {
  local reference="$1"
  [[ "${reference}" == *@sha256:* ]] || die "image must be pinned by digest: ${reference}"
  printf '%s\n' "${reference##*@}"
}

image_repository() {
  local reference="$1"
  printf '%s\n' "${reference%@*}"
}

compose() {
  local image_reference="$1"
  shift
  local repository digest project_dir
  repository="$(image_repository "${image_reference}")"
  digest="$(expected_digest "${image_reference}")"
  project_dir="$(dirname "${COMPOSE_FILE}")"

  if docker compose version >/dev/null 2>&1; then
    GATEWAY_IMAGE="${repository}" GATEWAY_DIGEST="${digest}" \
      docker compose \
        --project-name "${PROJECT_NAME}" \
        --project-directory "${project_dir}" \
        -f "${COMPOSE_FILE}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    GATEWAY_IMAGE="${repository}" GATEWAY_DIGEST="${digest}" \
      docker-compose \
        --project-name "${PROJECT_NAME}" \
        --project-directory "${project_dir}" \
        -f "${COMPOSE_FILE}" "$@"
  else
    die "Docker Compose is unavailable"
  fi
}

container_id() {
  docker inspect --format '{{.Id}}' "${CONTAINER_NAME}" 2>/dev/null
}

container_image_id() {
  docker inspect --format '{{.Image}}' "${CONTAINER_NAME}"
}

container_image_reference() {
  docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}"
}

image_id() {
  docker image inspect --format '{{.Id}}' "$1"
}

verify_reference() {
  local reference="$1"
  local expected repo_digests
  expected="$(expected_digest "${reference}")"

  if ! docker image inspect "${reference}" >/dev/null 2>&1; then
    docker pull "${reference}" >/dev/null
  fi

  repo_digests="$(docker image inspect --format '{{join .RepoDigests "\n"}}' "${reference}")"
  if ! grep -Fq "@${expected}" <<<"${repo_digests}"; then
    docker pull "${reference}" >/dev/null
    repo_digests="$(docker image inspect --format '{{join .RepoDigests "\n"}}' "${reference}")"
  fi
  grep -Fq "@${expected}" <<<"${repo_digests}" || {
    echo "${repo_digests}" >&2
    die "image does not expose expected digest ${expected}: ${reference}"
  }
}

container_probe() {
  local url="$1"
  docker exec \
    -e "PROBE_URL=${url}" \
    "${CONTAINER_NAME}" \
    /opt/venv/bin/python -c \
    'import os,sys,urllib.request; r=urllib.request.urlopen(os.environ["PROBE_URL"], timeout=3); sys.stdout.buffer.write(r.read())'
}

wait_for_container_health() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local status
  while (( SECONDS < deadline )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    case "${status}" in
      healthy) return 0 ;;
      unhealthy|exited|dead) return 1 ;;
    esac
    sleep 3
  done
  return 1
}

wait_for_readiness() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if container_probe "${READY_URL}" >/tmp/websocket-ready.json 2>/tmp/websocket-ready.err; then
      container_probe "${HEALTH_URL}" >/tmp/websocket-health.json
      return 0
    fi
    sleep 3
  done
  return 1
}

write_override() {
  local image="$1"
  local file="$2"
  cat >"${file}" <<EOF_OVERRIDE
services:
  ${SERVICE}:
    image: ${image}
EOF_OVERRIDE
}

record_state() {
  local directory="$1"
  mkdir -p "${directory}"
  cp --preserve=mode,timestamps "${COMPOSE_FILE}" "${directory}/compose.before.yaml"
  docker version >"${directory}/docker-version.txt" 2>&1 || true
  docker compose version >"${directory}/docker-compose-version.txt" 2>&1 || true
  docker inspect "${CONTAINER_NAME}" >"${directory}/container.before.json"
  docker image inspect "$(container_image_id)" >"${directory}/image.before.json"
  printf '%s\n' "$(container_image_reference)" >"${directory}/runtime-image-reference.before.txt"
  printf '%s\n' "${LEGACY_IMAGE}" >"${directory}/legacy-image.txt"
  printf '%s\n' "${TARGET_IMAGE}" >"${directory}/target-image.txt"
}

rollback_with_override() {
  local rollback_override="$1"
  compose "${LEGACY_IMAGE}" -f "${rollback_override}" \
    up -d --no-deps --force-recreate "${SERVICE}"
  wait_for_container_health && wait_for_readiness
}

apply_cutover() {
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  require_command docker

  local legacy_expected target_expected legacy_id target_id current_id current_reference
  legacy_expected="$(expected_digest "${LEGACY_IMAGE}")"
  target_expected="$(expected_digest "${TARGET_IMAGE}")"
  [[ "${legacy_expected}" == "${target_expected}" ]] ||
    die "authority-only cutover requires identical source and destination digests"

  verify_reference "${LEGACY_IMAGE}"
  verify_reference "${TARGET_IMAGE}"

  legacy_id="$(image_id "${LEGACY_IMAGE}")"
  target_id="$(image_id "${TARGET_IMAGE}")"
  [[ "${legacy_id}" == "${target_id}" ]] ||
    die "source and destination references do not resolve to the same local image ID"

  container_id >/dev/null || die "container is not present: ${CONTAINER_NAME}"
  current_id="$(container_image_id)"
  current_reference="$(container_image_reference)"
  [[ "${current_id}" == "${legacy_id}" ]] ||
    die "current container image ID is not the pinned legacy image; refusing blind cutover"
  [[ "${current_reference}" == ghcr.io/codestra-srl/* ]] ||
    die "current container is not using the Codestra-SRL registry authority: ${current_reference}"

  local stamp state_dir target_override rollback_override
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  state_dir="${STATE_ROOT}/${stamp}"
  target_override="${state_dir}/target.override.yaml"
  rollback_override="${state_dir}/rollback.override.yaml"

  record_state "${state_dir}"
  write_override "${TARGET_IMAGE}" "${target_override}"
  write_override "${LEGACY_IMAGE}" "${rollback_override}"
  mkdir -p "${STATE_ROOT}"
  printf '%s\n' "${state_dir}" >"${STATE_ROOT}/LAST_STATE"

  echo "Applying authority-only cutover using the exact same image digest..."
  compose "${TARGET_IMAGE}" -f "${target_override}" \
    up -d --no-deps --force-recreate "${SERVICE}"

  if ! wait_for_container_health || ! wait_for_readiness; then
    echo "Health/readiness failed; restoring the Codestra-SRL reference." >&2
    rollback_with_override "${rollback_override}" || true
    die "cutover failed and automatic rollback was invoked"
  fi

  local running_id running_reference
  running_id="$(container_image_id)"
  running_reference="$(container_image_reference)"
  if [[ "${running_id}" != "${target_id}" || "${running_reference}" != "${TARGET_IMAGE}" ]]; then
    rollback_with_override "${rollback_override}" || true
    die "post-cutover image authority mismatch; automatic rollback was invoked"
  fi

  docker inspect "${CONTAINER_NAME}" >"${state_dir}/container.after.json"
  docker image inspect "${TARGET_IMAGE}" >"${state_dir}/image.after.json"
  cp /tmp/websocket-health.json "${state_dir}/health.after.json"
  cp /tmp/websocket-ready.json "${state_dir}/readiness.after.json"
  cat >"${state_dir}/RESULT" <<EOF_RESULT
AUTHORITY_CUTOVER=PASS
SERVER_A=65.109.65.169
CONTAINER=${CONTAINER_NAME}
SOURCE_REFERENCE=${LEGACY_IMAGE}
TARGET_REFERENCE=${TARGET_IMAGE}
VERIFIED_DIGEST=${target_expected}
HEALTH_URL=${HEALTH_URL}
READINESS_URL=${READY_URL}
CUTOVER_AT=${stamp}
CODESTRA_BACKUP_RETAINED=true
EOF_RESULT
  echo "PASS: Server A now uses ${TARGET_IMAGE}; Codestra-SRL remains the rollback reference."
}

rollback_cutover() {
  require_command docker
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  [[ -f "${STATE_ROOT}/LAST_STATE" ]] || die "no recorded cutover state"

  local state_dir rollback_override
  state_dir="$(cat "${STATE_ROOT}/LAST_STATE")"
  rollback_override="${state_dir}/rollback.override.yaml"
  [[ -f "${rollback_override}" ]] || die "rollback override missing: ${rollback_override}"

  verify_reference "${LEGACY_IMAGE}"
  rollback_with_override "${rollback_override}" ||
    die "rollback container did not become healthy and ready"
  echo "PASS: restored ${LEGACY_IMAGE}"
}

status_cutover() {
  require_command docker
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  container_id >/dev/null || die "container is not present: ${CONTAINER_NAME}"

  docker inspect --format \
    'container={{.Name}} image_ref={{.Config.Image}} image_id={{.Image}} started={{.State.StartedAt}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${CONTAINER_NAME}"

  echo -n "health="
  container_probe "${HEALTH_URL}" || true
  echo
  echo -n "readiness="
  container_probe "${READY_URL}" || true
  echo
}

case "${1:-}" in
  apply) apply_cutover ;;
  rollback) rollback_cutover ;;
  status) status_cutover ;;
  -h|--help|help|"") usage ;;
  *) usage; die "unknown command: $1" ;;
esac

#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_IMAGE="${TARGET_IMAGE:-ghcr.io/appolon1908-hue/websocket-gateway@sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a}"
LEGACY_IMAGE="${LEGACY_IMAGE:-ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICE="${SERVICE:-websocket-gateway}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:6101/healthz}"
STATE_ROOT="${STATE_ROOT:-./websocket-authority-cutover}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-90}"

usage() {
  cat <<'EOF'
Repoint Server A from the Codestra-SRL registry path to the byte-identical
appolon1908-hue backup digest.

Required preparation:
  1. Run from the directory containing Server A's authoritative Compose file.
  2. Authenticate Docker to ghcr.io for appolon1908-hue package reads.
  3. Confirm deploy/image-authority.lock.yaml and mirror evidence are approved.

Environment overrides:
  COMPOSE_FILE, SERVICE, TARGET_IMAGE, LEGACY_IMAGE, HEALTH_URL, STATE_ROOT,
  TIMEOUT_SECONDS

Commands:
  server-a-switch-image-authority.sh apply
  server-a-switch-image-authority.sh rollback
  server-a-switch-image-authority.sh status
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "Docker Compose is unavailable"
  fi
}

expected_digest() {
  local reference="$1"
  [[ "${reference}" == *@sha256:* ]] || die "image must be pinned by digest: ${reference}"
  printf '%s\n' "${reference##*@}"
}

image_id() {
  docker image inspect --format '{{.Id}}' "$1"
}

container_id() {
  compose -f "${COMPOSE_FILE}" ps -q "${SERVICE}"
}

container_image_id() {
  local id
  id="$(container_id)"
  [[ -n "${id}" ]] || return 1
  docker inspect --format '{{.Image}}' "${id}"
}

wait_for_health() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if curl --fail --silent --show-error --max-time 5 "${HEALTH_URL}" >/tmp/websocket-health.json; then
      return 0
    fi
    sleep 3
  done
  return 1
}

write_override() {
  local image="$1"
  local file="$2"
  cat >"${file}" <<EOF
services:
  ${SERVICE}:
    image: ${image}
EOF
}

verify_reference() {
  local reference="$1"
  local expected
  expected="$(expected_digest "${reference}")"
  docker pull "${reference}" >/dev/null

  local repo_digests
  repo_digests="$(docker image inspect --format '{{join .RepoDigests "\n"}}' "${reference}")"
  grep -Fq "@${expected}" <<<"${repo_digests}" || {
    echo "${repo_digests}" >&2
    die "pulled image does not expose expected digest ${expected}"
  }
}

record_state() {
  local directory="$1"
  mkdir -p "${directory}"
  cp --preserve=mode,timestamps "${COMPOSE_FILE}" "${directory}/compose.before.yml"
  docker compose version >"${directory}/docker-compose-version.txt" 2>&1 || true
  docker version >"${directory}/docker-version.txt" 2>&1 || true

  local id
  id="$(container_id)"
  [[ -n "${id}" ]] || die "service ${SERVICE} has no running container"
  docker inspect "${id}" >"${directory}/container.before.json"
  docker image inspect "$(container_image_id)" >"${directory}/image.before.json"
  printf '%s\n' "${LEGACY_IMAGE}" >"${directory}/legacy-image.txt"
  printf '%s\n' "${TARGET_IMAGE}" >"${directory}/target-image.txt"
}

apply_cutover() {
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  require_command docker
  require_command curl

  local legacy_expected target_expected current_id legacy_id target_id
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

  current_id="$(container_image_id)" ||
    die "unable to inspect the current ${SERVICE} container"
  [[ "${current_id}" == "${legacy_id}" ]] ||
    die "current container is not running the pinned legacy image; refusing blind cutover"

  local stamp state_dir target_override rollback_override
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  state_dir="${STATE_ROOT}/${stamp}"
  target_override="${state_dir}/target.override.yml"
  rollback_override="${state_dir}/rollback.override.yml"

  record_state "${state_dir}"
  write_override "${TARGET_IMAGE}" "${target_override}"
  write_override "${LEGACY_IMAGE}" "${rollback_override}"
  printf '%s\n' "${state_dir}" >"${STATE_ROOT}/LAST_STATE"

  echo "Applying registry-authority cutover using the exact same digest..."
  compose -f "${COMPOSE_FILE}" -f "${target_override}" \
    up -d --no-deps --force-recreate "${SERVICE}"

  if ! wait_for_health; then
    echo "Health check failed; rolling back to Codestra-SRL reference." >&2
    compose -f "${COMPOSE_FILE}" -f "${rollback_override}" \
      up -d --no-deps --force-recreate "${SERVICE}" || true
    wait_for_health || true
    die "cutover failed and rollback was invoked"
  fi

  local running_id
  running_id="$(container_image_id)"
  [[ "${running_id}" == "${target_id}" ]] || {
    compose -f "${COMPOSE_FILE}" -f "${rollback_override}" \
      up -d --no-deps --force-recreate "${SERVICE}" || true
    die "post-cutover container image ID mismatch; rollback was invoked"
  }

  docker inspect "$(container_id)" >"${state_dir}/container.after.json"
  cp /tmp/websocket-health.json "${state_dir}/health.after.json"
  cat >"${state_dir}/RESULT" <<EOF
AUTHORITY_CUTOVER=PASS
SOURCE_REFERENCE=${LEGACY_IMAGE}
TARGET_REFERENCE=${TARGET_IMAGE}
VERIFIED_DIGEST=${target_expected}
HEALTH_URL=${HEALTH_URL}
CUTOVER_AT=${stamp}
EOF
  echo "PASS: Server A now uses ${TARGET_IMAGE}; Codestra-SRL remains the rollback reference."
}

rollback_cutover() {
  require_command docker
  require_command curl
  [[ -f "${STATE_ROOT}/LAST_STATE" ]] || die "no recorded cutover state"
  local state_dir rollback_override
  state_dir="$(cat "${STATE_ROOT}/LAST_STATE")"
  rollback_override="${state_dir}/rollback.override.yml"
  [[ -f "${rollback_override}" ]] || die "rollback override missing: ${rollback_override}"

  verify_reference "${LEGACY_IMAGE}"
  compose -f "${COMPOSE_FILE}" -f "${rollback_override}" \
    up -d --no-deps --force-recreate "${SERVICE}"
  wait_for_health || die "rollback container did not become healthy"
  echo "PASS: restored ${LEGACY_IMAGE}"
}

status_cutover() {
  require_command docker
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  compose -f "${COMPOSE_FILE}" ps "${SERVICE}"
  local id
  id="$(container_id)"
  if [[ -n "${id}" ]]; then
    docker inspect --format \
      'container={{.Name}} image_id={{.Image}} started={{.State.StartedAt}} status={{.State.Status}}' \
      "${id}"
  fi
  curl --fail --silent --show-error --max-time 5 "${HEALTH_URL}" || true
  echo
}

case "${1:-}" in
  apply) apply_cutover ;;
  rollback) rollback_cutover ;;
  status) status_cutover ;;
  -h|--help|help|"") usage ;;
  *) usage; die "unknown command: $1" ;;
esac

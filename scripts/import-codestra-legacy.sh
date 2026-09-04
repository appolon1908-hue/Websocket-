#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_REPOSITORY="${1:?source repository is required}"
SOURCE_COMMIT="${2:?source commit is required}"
LEGACY_IMAGE="${3:?legacy image digest reference is required}"
DESTINATION_DIGEST="${4:?destination digest reference is required}"

SERVER_A_HOST="${SERVER_A_HOST:-65.109.65.169}"
SERVER_A_CONTAINER="${SERVER_A_CONTAINER:-codestra-websocket-gateway-gateway-1}"
SERVER_A_COMPOSE_FILE="${SERVER_A_COMPOSE_FILE:-/home/codestra-admin/releases/middleware-69723c25a27e2a64cf55539c7d6df362a33579a4/websocket_gateway/compose.yaml}"
RUNTIME_OBSERVED_AT="${RUNTIME_OBSERVED_AT:-2026-09-01T14:01:48Z}"

ROOT="$(git rev-parse --show-toplevel)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

SOURCE_DIR="${WORKDIR}/source"
DEST_DIR="${ROOT}/legacy/codestra-srl/source"

[[ "${LEGACY_IMAGE}" == *@sha256:* ]] || {
  echo "legacy image must be pinned by sha256 digest: ${LEGACY_IMAGE}" >&2
  exit 1
}
[[ "${DESTINATION_DIGEST}" == *@sha256:* ]] || {
  echo "destination image must be pinned by sha256 digest: ${DESTINATION_DIGEST}" >&2
  exit 1
}

legacy_digest="${LEGACY_IMAGE##*@}"
destination_digest="${DESTINATION_DIGEST##*@}"
[[ "${legacy_digest}" == "${destination_digest}" ]] || {
  echo "source/destination digest mismatch: ${legacy_digest} != ${destination_digest}" >&2
  exit 1
}

digest_hex="${legacy_digest#sha256:}"
destination_repository="${DESTINATION_DIGEST%@*}"
backup_tag="${destination_repository}:backup-codestra-srl-${digest_hex:0:12}"

git clone --quiet --filter=blob:none --no-checkout \
  "https://github.com/${SOURCE_REPOSITORY}.git" "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" fetch --quiet --depth=1 origin "${SOURCE_COMMIT}"
git -C "${SOURCE_DIR}" checkout --quiet --detach "${SOURCE_COMMIT}"

actual_source_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
[[ "${actual_source_commit}" == "${SOURCE_COMMIT}" ]] || {
  echo "source commit mismatch: expected ${SOURCE_COMMIT}, got ${actual_source_commit}" >&2
  exit 1
}

rm -rf "${DEST_DIR}"
mkdir -p "${DEST_DIR}"

python3 - "${SOURCE_DIR}" "${DEST_DIR}" <<'PY'
from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2]).resolve()

# These support files do not all contain "websocket" in their path, but were
# part of the legacy gateway's release/certification surface when present.
explicit = {
    "CANDIDATE_IMAGE.txt",
    "docker-compose.yml",
    "scripts/stage2_test.sh",
    "tests/test_stage2_connection.py",
    "tests/test_stage3_replay.py",
    "sql/migrations/versions/0004_create_websocket_messages.sql",
}

tracked_raw = subprocess.check_output(
    ["git", "-C", str(source), "ls-files", "-z"]
)
tracked = [entry.decode("utf-8") for entry in tracked_raw.split(b"\0") if entry]

selected: list[str] = []
for relative in tracked:
    lowered = relative.lower()
    if (
        lowered.startswith("websocket_gateway/")
        or lowered.startswith("deploy/websocket-")
        or "websocket" in lowered
        or relative in explicit
    ):
        selected.append(relative)

if not selected:
    raise SystemExit("no WebSocket source assets were selected")

for relative in sorted(set(selected)):
    src = source / relative
    dst = destination / relative
    if src.is_symlink():
        raise SystemExit(f"refusing to import symlink: {relative}")
    if not src.is_file():
        continue
    if src.name == ".env" or src.suffix in {".pem", ".key", ".p12", ".pfx"}:
        raise SystemExit(f"refusing secret-bearing file name: {relative}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

manifest_lines: list[str] = []
for path in sorted(p for p in destination.rglob("*") if p.is_file()):
    relative = path.relative_to(destination).as_posix()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest_lines.append(f"{digest}  {relative}")

(destination / "MANIFEST.sha256").write_text(
    "\n".join(manifest_lines) + "\n",
    encoding="utf-8",
)
(destination / "SELECTION.txt").write_text(
    "\n".join(sorted(set(selected))) + "\n",
    encoding="utf-8",
)
PY

python3 -m compileall -q "${DEST_DIR}/websocket_gateway"

imported_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
mkdir -p "${ROOT}/legacy/codestra-srl" "${ROOT}/deploy"
cat >"${ROOT}/legacy/codestra-srl/SOURCE_PROVENANCE.md" <<EOF_PROVENANCE
# Codestra-SRL WebSocket legacy backup

This directory is a read-only source snapshot imported without modification
from \`${SOURCE_REPOSITORY}\` at commit \`${SOURCE_COMMIT}\`.

## Server A runtime authority

- Runtime inventory captured: \`${RUNTIME_OBSERVED_AT}\`
- Server A host: \`${SERVER_A_HOST}\`
- Observed container: \`${SERVER_A_CONTAINER}\`
- Observed OCI revision: \`${SOURCE_COMMIT}\`
- Observed legacy image: \`${LEGACY_IMAGE}\`
- Exact mirrored digest: \`${DESTINATION_DIGEST}\`
- Discovery-only backup tag: \`${backup_tag}\`
- Image rebuilt during migration: \`false\`

## Source snapshot integrity

- Imported at: \`${imported_at}\`
- Selection manifest: \`source/SELECTION.txt\`
- Content checksums: \`source/MANIFEST.sha256\`

The Codestra-SRL repository and registry reference remain rollback-only backup
authority. New development, builds, fixes, and release evidence belong to
\`appolon1908-hue/Websocket-\`.

Server A must not be repointed until \`evidence/legacy-image-mirror.json\`
reports \`verification=PASS\` for \`${legacy_digest}\`. The host-side switch
must then verify the running image ID, Docker health, application readiness,
and automatic rollback.
EOF_PROVENANCE

cat >"${ROOT}/deploy/image-authority.lock.yaml" <<EOF_LOCK
schema_version: 2
service: codestra-websocket-gateway
canonical:
  source_repository: https://github.com/appolon1908-hue/Websocket-
  image_repository: ${destination_repository}
legacy_backup:
  role: rollback_only
  source_repository: https://github.com/${SOURCE_REPOSITORY}
  source_commit: ${SOURCE_COMMIT}
  source_relation: observed_oci_revision
  source_snapshot: legacy/codestra-srl/source
  source_image: ${LEGACY_IMAGE}
  mirrored_tag: ${backup_tag}
  mirrored_digest: ${DESTINATION_DIGEST}
  mirror_evidence: evidence/legacy-image-mirror.json
server_a:
  host: ${SERVER_A_HOST}
  runtime_observed_at: ${RUNTIME_OBSERVED_AT}
  compose_project: codestra-websocket-gateway
  compose_service: gateway
  observed_container: ${SERVER_A_CONTAINER}
  compose_file: ${SERVER_A_COMPOSE_FILE}
  container_health_url: http://127.0.0.1:8080/healthz
  container_readiness_url: http://127.0.0.1:8080/readyz
policy:
  rebuild_legacy_image: false
  require_exact_digest_match: true
  require_running_image_identity_match: true
  require_container_health: true
  require_application_readiness: true
  require_automatic_rollback: true
  allow_new_gateway_promotion_in_this_change: false
  delete_codestra_backup: false
EOF_LOCK

echo "Imported $(wc -l <"${DEST_DIR}/SELECTION.txt") tracked WebSocket assets."

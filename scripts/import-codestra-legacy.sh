#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_REPOSITORY="${1:?source repository is required}"
SOURCE_COMMIT="${2:?source commit is required}"
LEGACY_IMAGE="${3:?legacy image digest reference is required}"
DESTINATION_DIGEST="${4:?destination digest reference is required}"

ROOT="$(git rev-parse --show-toplevel)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

SOURCE_DIR="${WORKDIR}/source"
DEST_DIR="${ROOT}/legacy/codestra-srl/source"

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
tracked = [
    entry.decode("utf-8")
    for entry in tracked_raw.split(b"\0")
    if entry
]

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
cat >"${ROOT}/legacy/codestra-srl/SOURCE_PROVENANCE.md" <<EOF
# Codestra-SRL WebSocket legacy backup

This directory is a read-only source backup imported without modification from
\`${SOURCE_REPOSITORY}\` at commit
\`${SOURCE_COMMIT}\`.

- Imported at: \`${imported_at}\`
- Server A legacy image observed before migration:
  \`${LEGACY_IMAGE}\`
- Canonical mirrored digest location:
  \`${DESTINATION_DIGEST}\`
- Selection manifest: \`source/SELECTION.txt\`
- Content checksums: \`source/MANIFEST.sha256\`

The old Codestra-SRL source and image remain rollback-only authority. New
development, builds, fixes, and release evidence belong to
\`appolon1908-hue/Websocket-\`.

The runtime image was not rebuilt during the authority migration. Server A must
not be repointed until the destination registry reports the exact same
\`sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a\`
digest and the local cutover script verifies health and rollback.
EOF

mkdir -p "${ROOT}/deploy"
cat >"${ROOT}/deploy/image-authority.lock.yaml" <<EOF
schema_version: 1
service: codestra-websocket-gateway
canonical:
  source_repository: https://github.com/appolon1908-hue/Websocket-
  image_repository: ghcr.io/appolon1908-hue/websocket-gateway
legacy_backup:
  source_repository: https://github.com/${SOURCE_REPOSITORY}
  source_commit: ${SOURCE_COMMIT}
  source_snapshot: legacy/codestra-srl/source
  source_image: ${LEGACY_IMAGE}
  mirrored_tag: ghcr.io/appolon1908-hue/websocket-gateway:backup-codestra-srl-9e4e7f562cd6
  mirrored_digest: ${DESTINATION_DIGEST}
server_a:
  compose_project: middleware
  compose_service: websocket-gateway
  observed_container: middleware_websocket-gateway_1
  loopback_binding: 127.0.0.1:6101
  health_url: http://127.0.0.1:6101/healthz
policy:
  legacy_role: rollback_only
  rebuild_legacy_image: false
  require_exact_digest_match: true
  require_health_check: true
  require_automatic_rollback: true
  allow_new_gateway_promotion_in_this_change: false
EOF

echo "Imported $(wc -l <"${DEST_DIR}/SELECTION.txt") tracked WebSocket assets."

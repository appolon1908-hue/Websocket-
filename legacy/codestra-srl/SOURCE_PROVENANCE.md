# Codestra-SRL WebSocket legacy backup

This directory is a read-only source snapshot imported without modification
from `Codestra-SRL/codestra-middleware` at commit `9118e5bc01f9ce4a52add8753c096d061cd84848`.

## Server A runtime authority

- Runtime inventory captured: `2026-09-01T14:01:48Z`
- Server A host: `65.109.65.169`
- Observed container: `codestra-websocket-gateway-gateway-1`
- Observed OCI revision: `9118e5bc01f9ce4a52add8753c096d061cd84848`
- Observed legacy image: `ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd`
- Exact mirrored digest: `ghcr.io/appolon1908-hue/websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd`
- Discovery-only backup tag: `ghcr.io/appolon1908-hue/websocket-gateway:backup-codestra-srl-1c8f28d36279`
- Image rebuilt during migration: `false`

## Source snapshot integrity

- Imported at: `2026-09-04T18:55:27Z`
- Selection manifest: `source/SELECTION.txt`
- Content checksums: `source/MANIFEST.sha256`

The Codestra-SRL repository and registry reference remain rollback-only backup
authority. New development, builds, fixes, and release evidence belong to
`appolon1908-hue/Websocket-`.

Server A must not be repointed until `evidence/legacy-image-mirror.json`
reports `verification=PASS` for `sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd`. The host-side switch
must then verify the running image ID, Docker health, application readiness,
and automatic rollback.

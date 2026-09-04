# Codestra-SRL WebSocket legacy backup

This directory is a read-only source backup imported without modification from
`Codestra-SRL/codestra-middleware` at commit
`167bd6221911ec3fa988d719eb259646fa90f296`.

- Imported at: `2026-09-04T18:42:33Z`
- Server A legacy image observed before migration:
  `ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a`
- Canonical mirrored digest location:
  `ghcr.io/appolon1908-hue/websocket-gateway@sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a`
- Selection manifest: `source/SELECTION.txt`
- Content checksums: `source/MANIFEST.sha256`

The old Codestra-SRL source and image remain rollback-only authority. New
development, builds, fixes, and release evidence belong to
`appolon1908-hue/Websocket-`.

The runtime image was not rebuilt during the authority migration. Server A must
not be repointed until the destination registry reports the exact same
`sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a`
digest and the local cutover script verifies health and rollback.

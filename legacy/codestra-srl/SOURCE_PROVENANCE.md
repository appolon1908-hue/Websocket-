# Codestra-SRL WebSocket legacy backup

This directory is a read-only source backup imported without modification from
`Codestra-SRL/codestra-middleware` at commit
`9118e5bc01f9ce4a52add8753c096d061cd84848`.

- Imported at: `2026-09-04T18:43:39Z`
- Server A legacy image observed before migration:
  `ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd`
- Canonical mirrored digest location:
  `ghcr.io/appolon1908-hue/websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd`
- Selection manifest: `source/SELECTION.txt`
- Content checksums: `source/MANIFEST.sha256`

The old Codestra-SRL source and image remain rollback-only authority. New
development, builds, fixes, and release evidence belong to
`appolon1908-hue/Websocket-`.

The runtime image was not rebuilt during the authority migration. Server A must
not be repointed until the destination registry reports the exact same
`sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd`
digest and the local cutover script verifies health and rollback.

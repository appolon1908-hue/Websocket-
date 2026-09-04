# WebSocket authority migration: Codestra-SRL to appolon1908-hue

## Decision

`appolon1908-hue/Websocket-` is the forward source and image authority for the
Codestra agent real-time WebSocket gateway. The existing Codestra-SRL source,
registry reference, and Server A rollback evidence are retained as backup.

This migration deliberately separates two releases:

1. **Registry-authority cutover.** Mirror the exact image already running on
   Server A without rebuilding it, verify the destination digest is identical,
   and then recreate only the gateway service with the new registry reference.
   Runtime code and data do not change.
2. **New gateway promotion.** Build and certify the Go gateway in this
   repository at an exact protected commit and promote that different digest in
   a separate release. This migration does not authorize that promotion.

## Reconciled Server A authority

The production capability inventory captured on September 1, 2026 identifies:

| Field | Reconciled value |
|---|---|
| Server A | `65.109.65.169` |
| Compose project | `codestra-websocket-gateway` |
| Service | `gateway` |
| Container | `codestra-websocket-gateway-gateway-1` |
| Deployment configuration | `/home/codestra-admin/releases/middleware-69723c25a27e2a64cf55539c7d6df362a33579a4/websocket_gateway/compose.yaml` |
| Running image | `ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd` |
| OCI source revision | `9118e5bc01f9ce4a52add8753c096d061cd84848` |

The older `sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a`
coordinate belongs to an earlier immutable production tuple. It is not the most
recent observed Server A runtime image and is therefore not the authority-only
cutover target in this change.

## Completed repository and image migration

The following exact authorities are now recorded:

| Purpose | Immutable authority |
|---|---|
| Legacy source snapshot | `Codestra-SRL/codestra-middleware@9118e5bc01f9ce4a52add8753c096d061cd84848` |
| Legacy rollback image | `ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd` |
| New authoritative mirror | `ghcr.io/appolon1908-hue/websocket-gateway@sha256:1c8f28d3627955c0d07f8a3f2e4187edb0770f3a9fc7cbc7dc9d819fcd255ffd` |
| Discovery-only backup tag | `ghcr.io/appolon1908-hue/websocket-gateway:backup-codestra-srl-1c8f28d36279` |

`evidence/legacy-image-mirror.json` records `verification=PASS`, the identical
source/destination digest, and `rebuilt=false`. Deployments must use the digest
reference; the tag is only for package discovery.

The source importer preserves all tracked WebSocket paths available at the OCI
revision, plus known support paths when present. It rejects symlinks, private
keys, actual `.env` files, and common token signatures. The result is recorded
in:

- `legacy/codestra-srl/source/SELECTION.txt`
- `legacy/codestra-srl/source/MANIFEST.sha256`
- `legacy/codestra-srl/SOURCE_PROVENANCE.md`
- `deploy/image-authority.lock.yaml`

## Server A cutover

The live host has not been changed by the repository migration. Server A is not
currently enrolled in the connected server manager, so the exact host-side
identity, health, readiness, and rollback gates must be executed on the host.

From a trusted checkout of this branch:

```bash
git checkout migration/codestra-srl-websocket-backup
sudo ./scripts/server-a-switch-image-authority.sh status
sudo ./scripts/server-a-switch-image-authority.sh apply
```

The script refuses the cutover unless:

- source and destination references are both digest-pinned;
- both references use the exact same digest and local image ID;
- the current container still resolves to the Codestra-SRL image ID;
- the Compose project, service, container, and deployment file match Server A;
- Docker reports the recreated container healthy;
- `/readyz` succeeds from inside the container;
- the post-cutover container reports the exact appolon1908-hue digest reference.

A failed identity, health, or readiness check automatically recreates the
service using the Codestra-SRL digest. Manual rollback is:

```bash
sudo ./scripts/server-a-switch-image-authority.sh rollback
```

Evidence is stored under `websocket-authority-cutover/<UTC timestamp>/` unless
`STATE_ROOT` is overridden.

## Backup retention

Do not delete the Codestra-SRL package, source repository, local image, or
rollback evidence. Keep them until the registry-authority cutover and a manual
rollback rehearsal both pass, and until the later Go gateway release has its
own immutable build, staging certification, production canary, and rollback
proof.

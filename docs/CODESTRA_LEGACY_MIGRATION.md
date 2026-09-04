# WebSocket authority migration: Codestra-SRL to appolon1908-hue

## Decision

`appolon1908-hue/Websocket-` becomes the only source and image authority for
future WebSocket development. The legacy implementation from
`Codestra-SRL/codestra-middleware` is retained under
`legacy/codestra-srl/` and the old registry reference is retained strictly as a
rollback backup.

This change deliberately separates two releases:

1. **Authority-only cutover.** Copy the existing Server A image manifest and
   layers without rebuilding, verify that the destination digest is exactly
   `sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a`,
   then repoint Server A to the new registry path. Runtime code does not change.
2. **New gateway promotion.** Build and certify the Go gateway from this
   repository at an exact protected commit, then promote that different digest
   in a separate release. This migration does not authorize that promotion.

## Pinned authorities

| Purpose | Immutable authority |
|---|---|
| Legacy source snapshot | `Codestra-SRL/codestra-middleware@9ba5645d0ae72be12087fb8d473101ab75405804` |
| Server A image observed before migration | `ghcr.io/codestra-srl/codestra-websocket-gateway@sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a` |
| New mirrored location | `ghcr.io/appolon1908-hue/websocket-gateway@sha256:9e4e7f562cd6d278635f33fe69af75e5e54fed86421a55a0d172e750c6522b9a` |
| Backup tag | `ghcr.io/appolon1908-hue/websocket-gateway:backup-codestra-srl-9e4e7f562cd6` |

The tag is for human discovery only. Deployments must use the digest reference.

## Repository migration

The `Import and mirror Codestra-SRL WebSocket legacy` workflow:

1. Checks out the pinned Codestra-SRL commit.
2. Copies every tracked path whose name or directory contains `websocket`,
   plus the known Compose, candidate-image, Stage 2/3 test, and SQL migration
   support files.
3. Rejects symlinks, private-key file types, actual `.env` files, and common
   GitHub token/private-key signatures.
4. Writes a selected-file inventory and SHA-256 manifest.
5. Mirrors the old OCI image with `skopeo --preserve-digests`.
6. Refuses success unless the new location reports the exact old digest.
7. Commits machine-readable mirror evidence.

When the source GHCR package is private, repository secrets
`CODESTRA_GHCR_TOKEN` (`read:packages`) and optionally `CODESTRA_GHCR_USER`
are required. The destination write uses this repository's `GITHUB_TOKEN`.

## Server A cutover

Do not edit the existing Compose file by hand. From Server A's Compose
directory, run:

```bash
git clone https://github.com/appolon1908-hue/Websocket-.git
cd Websocket-
git checkout migration/codestra-srl-websocket-backup

cd /path/to/server-a/middleware-compose
/path/to/Websocket-/scripts/server-a-switch-image-authority.sh status
/path/to/Websocket-/scripts/server-a-switch-image-authority.sh apply
```

The script refuses the cutover unless:

- both registry references are digest-pinned;
- both references have the same digest;
- both pull to the same local image ID;
- the running service currently uses that exact image ID;
- the recreated service becomes healthy at `http://127.0.0.1:6101/healthz`;
- the post-cutover container uses the expected image ID.

On a failed health or identity check, it automatically recreates the service
with the Codestra-SRL digest. Manual rollback is:

```bash
/path/to/Websocket-/scripts/server-a-switch-image-authority.sh rollback
```

Cutover evidence is stored under `websocket-authority-cutover/<UTC timestamp>/`
beside the Compose project unless `STATE_ROOT` is overridden.

## Retirement rule

Do not delete the Codestra-SRL image, source repository, local image, or
rollback evidence until all of the following are true:

- the mirrored digest has been independently pulled and verified;
- the authority-only cutover has passed;
- rollback has been rehearsed successfully;
- the new Go gateway has its own immutable image, staging certification, and
  production rollback proof;
- the agreed retention window has elapsed.

The legacy source is not an active development fork. Security fixes must be
implemented in the new authority and released as a new digest.

# Bundled attachment storage

Release CI builds MinIO from its official upstream source instead of pulling
discontinued `minio/minio` or `minio/mc` Docker Hub images. `Dockerfile.storage`
fixes the upstream commit and source archive SHA256. The multi-architecture
`ghcr.io/0800x/loom-minio` image is published for linux/amd64 and linux/arm64.
Fresh production installs only pull the image tagged with the exact Loom source
commit; they do not compile MinIO on the Home Node. The image retains the
upstream license/notice and source archive under `/usr/share/minio-source/source.tar.gz`.

MinIO is a separate **AGPLv3** component; Loom's own code remains GPLv3-only.
Upstream source: <https://github.com/minio/minio/tree/7aac2a2c5b7c882e68c1ce017d8256be2feea27f>.
The upstream community repository is archived and has no ongoing maintenance
commitment. Review its security status before production use. Keep its API and
console on the private Docker network; neither 9000 nor 9001 is published by
this bundle.

Bucket initialization uses the Node image's existing S3 SDK. It preserves an
existing bucket, creates a missing bucket with the configured credentials, and
stops on authentication failure. It never changes storage credentials.

For an existing installation, setup pins the current MinIO image by its local
SHA256 in `docker-compose.storage-legacy.yml`. This keeps the existing binary
and data format; source updates do not silently migrate object storage. The
manager includes this overlay for service commands. Review backups and perform
a separate storage migration before removing that protected overlay.

Compose **2.24.4 or newer** is required for the protected storage override.
The GitHub Actions release pipeline builds and publishes the image. A Home Node
needs network access to pull it (or a preloaded image archive); the server source
bundle is not an offline image bundle.

Normal Home Node installation does not build MinIO or Loom Node on the target
server. GitHub Actions builds and publishes both multi-architecture OCI images
to GHCR under the exact Loom source commit. The installer verifies the selected
release and prebuilt Node Manager, runs `docker compose pull`, then starts the
stack and waits for service health checks. It does not invoke `docker build`,
Go, npm, or a source compilation step on the Home Node.

The Go module proxy and BuildKit cache described by older development notes are
only relevant to maintainers building the MinIO image inside CI or running an
explicit source-build workflow. They are not part of the supported one-command
Home Node installation. This bundle is not an offline-image bundle: the Home
Node must be able to pull the immutable Node and MinIO tags from GHCR (or have
the matching images preloaded by an operator).

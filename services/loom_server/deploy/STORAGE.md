# Bundled attachment storage

Fresh Linux installs build MinIO from its official upstream source instead of
pulling discontinued `minio/minio` or `minio/mc` Docker Hub images.
`Dockerfile.storage` fixes the upstream commit and source archive SHA256. It
builds for the Docker host architecture with Go path trimming. The image retains
the upstream license/notice and corresponding source archive under
`/usr/share/minio-source/source.tar.gz`.

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
Fresh source builds need internet access, additional build time and sufficient
RAM. A server source bundle is not an offline image bundle.

The source build uses the selected Go module proxy. Some upstream dependency repositories are no longer public, so direct VCS downloads cannot replace a complete module proxy. Select an Iran mirror explicitly when the official proxy refuses access. `go.sum`, read-only module resolution and the public Go checksum database remain enabled. A network refusal is a build failure, not a reason to reset retained data. First installation still compiles storage and can take several minutes; no prebuilt storage image is advertised here.

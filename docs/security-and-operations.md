# Security and operations

Loom is an alpha without an independent security audit. Keep identity/recovery
backups and test the installation before relying on it for important data.

## Connections and identity

Client-to-node connections require authenticated HTTPS. A verification failure
does not authorize a transport fallback. Device-link approvals bind both devices
and the request to a signed exchange. Old pairing formats are rejected rather
than silently accepted. Recovery does not regenerate an existing identity.

Keep MLS group recovery and membership limitations in mind; see
[groups](groups-mls-v1.md), [routing](profile-security-routing-2026-09-27.md) and
[compatibility](compatibility.md). Experimental session providers are described
in the architecture documents and do not establish production readiness.

## Operating a node

The first-party installer pins source and verifies its archive before root
installation. Official updates use a protected publisher policy bound to `0800x/Loom` over
authenticated HTTPS, with an immutable revision/digest and rollback sequence.
Existing operator policies continue to require a protected release allowlist. Never replace verification failures with a moving-branch
root install. The installation and destructive commands are restricted to the
owned `/opt/loom-node` directory and labelled resources.

Database, attachment storage, admin tokens, TURN and group media use private
credentials. Do not reuse credentials across services. An invalid existing
credential stops setup; restore a valid backup rather than replacing identity or
secret material silently. Keep `.env`, media configuration and backups private.

Use the same Android signing key for subsequent application updates. Missing
signing credentials must not silently select debug signing. Unsigned desktop
engineering builds are labelled in their manifests.

## Backups and diagnostics

Back up the database, attachments, Node identity and configuration together.
Test restoration on an isolated installation. Source updates interrupt active
connections and calls; retain their backups until the updated service is healthy.
Do not share raw signaling, credentials, recovery exports or private logs.

For installation and common errors, see [Home Node setup](node-setup.md).

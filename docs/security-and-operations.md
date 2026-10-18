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

## Request admission and reverse proxies

HTTP admission runs before all v1/v2 delivery adapters. IP, endpoint class,
credential, account and device quotas use process-local token buckets. They reset
on restart and are not shared across replicas. Bursts consume tokens immediately;
refill is continuous over a minute. There are 10,000 exact subject entries and
256 shared overflow buckets. Exact entries are not evicted to reset active
quotas. Overflow collisions can conservatively throttle unrelated subjects;
this bounds memory without rejecting every new subject merely because the exact
map filled. It does not guarantee availability under a distributed flood.

By default, only the TCP socket peer determines the client IP. Behind Caddy or
Nginx, set `LOOM_TRUSTED_PROXY_CIDRS` to a comma-separated list of the actual
proxy IP CIDRs, for example `127.0.0.1/32,::1/128` for a host loopback proxy.
Docker bridge proxy addresses must be configured from the actual deployment;
do not trust a whole shared/tenant subnet. Docker Compose passes `.env` into the
node service. Restart the node after changes.

Only a connection from a configured proxy can supply `X-Forwarded-For`. The node
walks the chain from right to left and stops at the first untrusted hop. The
proxy must overwrite or correctly append the immediate client's IP; trusting
arbitrary client-supplied header contents defeats this boundary. Invalid or
oversized chains fall back to the socket peer. Invalid CIDR configuration,
including catch-all `/0` networks, fails startup. No `Forwarded` or `X-Real-IP`
header is trusted. WebSocket realtime upgrade admission uses the same policy.

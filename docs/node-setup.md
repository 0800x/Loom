# Loom Home Node setup

This page is a short entry point. The maintained installation instructions,
all wizard options, DNS and firewall requirements, regional mirror behavior,
post-install operations and troubleshooting are documented in the main
[README — Host a Home Node](../README.md#host-a-home-node).

## Install or reconfigure

Connect to a supported Linux host over SSH and run:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/0800x/Loom/main/install.sh \
  -o /tmp/loom-install.sh &&
bash /tmp/loom-install.sh
```

For a server using the Liara mirror profile:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/0800x/Loom/main/install.sh \
  -o /tmp/loom-install.sh &&
bash /tmp/loom-install.sh --downloads liara
```

For a server using the Arvan mirror profile:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/0800x/Loom/main/install.sh \
  -o /tmp/loom-install.sh &&
bash /tmp/loom-install.sh --downloads arvan
```

The bootstrap verifies a pinned source revision before privileged setup.
Do not disable integrity checks or remove TLS verification.

## Important network requirements

- Public HTTPS requires a DNS A record pointing to the VPS provider's public
  ingress IP and inbound TCP 80/443. A stale AAAA record must be corrected or
  removed. A CDN proxy must not break ACME validation or forwarding.
- Liara/Arvan mirror profiles do not proxy GitHub or GHCR. Loom Node and MinIO
  images still come from GHCR; the source bootstrap still comes from GitHub.
- TURN uses TCP/UDP 3478 and UDP 49160–49200. Group-call media uses TCP 7881
  and UDP 50000–50100. Only open these media ports when those features are used.
- The app's Node endpoint is bound to loopback port 7483. Do not expose it
  directly to the Internet.

Use the main README as the canonical guide because it explains what the
regional mirror profiles do and, just as importantly, what they do not do.
For terminal manager operations, see [Node Manager](node-manager.md). For
advanced deployment and recovery, see
[the deployment reference](../services/loom_server/deploy/README.md).
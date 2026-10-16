# Run a Loom Home Node

Node Manager is the terminal interface for the installed Docker-based Home Node.
It operates your installation, not a hosted control panel. The first alpha uses
`0800x/Loom` as its source repository and `main` as its update channel.

## First installation

1. Prepare a Linux host, a domain and reachable TCP 80/443. Point public DNS at
   the host. Use a disposable host for alpha testing and retain working backups.
2. Obtain the bootstrap from a trusted checkout and authenticate the approved
   full revision and Git-tar digest. Run the unprivileged bootstrap described in
   the [deployment guide](../services/loom_server/deploy/README.md#linux-integrity-verified-installation-and-updates).
3. Choose a domain and proxy with `--domain chat.example.com --proxy auto`.
   `auto` preserves an existing selection, uses active host Nginx when detected,
   otherwise Caddy, and refuses to take over ports used by unknown services.
4. Keep registration approval and trusted federation unless deliberately choosing
   another policy. The installer generates private service credentials; keep
   configuration and Node identity backups private.
5. Open `loom`. Check **Overview**, **Services**, **Network & TLS** and **Security**.
   Local readiness alone does not prove that public HTTPS works. Visit your actual
   public node page and test its QR/link from a client on another network.
6. Create two fictional test accounts, approve pending registrations and test
   a conversation before inviting other alpha testers.

The installation directory is `/opt/loom-node`. The public connection page belongs
to the domain you configure; this project does not assign a hosted service domain.
Windows uses the separate [PowerShell production setup](../services/loom_server/deploy/README.md#windows-production-setup).

**Easy Mode** uses host Node.js, SQLite and filesystem attachments for local
experiments. It permits HTTP only on exact development loopback addresses;
LAN use requires authenticated HTTPS. Public deployment uses the production stack.

## Navigation and daily operation

Use **↑/↓** (or **j/k**) to select, **Tab / Shift+Tab** to change focus and
**Enter / Space** to open actions. **Esc** returns to the sidebar, **r** refreshes,
**?** shows help and **q** exits. Read the confirmation before approving an action.

| Page | Useful checks |
| --- | --- |
| Overview | Manager, installed and running Node revisions; readiness; resource use |
| Services | Container health and deliberate service operations |
| Users / Registrations | Account list and pending registration approvals |
| Federation | Verified discovery, identity fingerprints, trust and health |
| Federation Queue | Pending, retrying, failed and delivered federation work |
| Calls / Groups | Calling configuration and group administration |
| Public page | Published connection information and optional operator support links |
| Network & TLS | Public endpoint, DNS, certificate expiry and reachability |
| Database / Storage / Logs | Persistence, attachments and diagnostics |
| Security / Backup / Maintenance | Identity/configuration checks and backup operations |
| Updates | Selected repository/branch, exact revisions and update progress |

An unavailable probe is not a healthy result. Diagnose the reported service,
certificate or identity failure before changing trust or retrying delivery.

## Federation

Federation lets people on separate Home Nodes exchange direct conversations.
A remote address triggers discovery of the recipient's domain. Discovery binds
its HTTPS endpoint to a signed Node identity; authenticated federation envelopes
carry encrypted messages. Nodes can observe routing metadata, while message
content is decrypted by authorized devices.

1. Use compatible Loom clients and nodes. Set both operators' **Federation** policy
   to **Trusted** for an explicitly approved connection.
2. Resolve a fictional remote contact, for example `ethan@chat.example.net`.
   Discovery is demand-driven; an empty table before resolving a remote address
   is expected.
3. Inspect the discovered domain and fingerprint. Compare the identity through
   a trusted channel, select **Verify**, then **Trust** the intended node.
4. Repeat the trust review at the other node if two-way delivery is required.
5. Watch **Federation Queue** and test send/receive across the nodes. Node acceptance
   is distinct from evidence of recipient delivery or reading.

**Open** accepts any compatible verified node; **Local** restricts to local/private
nodes; **Hybrid** allows trusted public nodes plus local/private nodes. **Disabled**
turns federation off. A blocked node remains blocked. **Forget** removes a cached
record and may allow later rediscovery; it is not a block operation.

**Retry selected** and **Retry all failed** reschedule failed delivery records.
**Purge dead-letter** deletes failed records and requires confirmation. Inspect
signature, policy and endpoint failures before retrying. Changing a trust policy
is not a remedy for an invalid signature or changed node identity.

Cross-node MLS membership is not supported in this alpha. Federation does not
restore lost MLS state or turn live calls into delayed messages.

## Calling

Open **Calls** to configure TURN and enable voice/video. For group calls choose
**Set up group calls**, review the media-service configuration and port exposure,
then apply. Required media/firewall ports depend on that configuration; TCP 443
alone does not establish media reachability. Keep media API keys private.

Test actual calls from two physical devices on different networks, including TURN
relay and microphone/camera permissions. A passing control-plane probe or mock
call test does not establish that media flows. See [group calls](group-calls.md).

## Updates from source

The running manager checks the configured branch every **60 seconds** and compares
full commit SHAs. A check does not install software. Select **Updates → Install
update** to run the automated download/build/install procedure explicitly.
There is no unattended update daemon or timer in this alpha.

Before execution, the exact revision and canonical uncompressed Git-tar SHA256
must appear in root-owned mode-0600 `/etc/loom/approved-releases`:

```text
0800x/Loom REVIEWED_FULL_COMMIT_SHA APPROVED_GIT_TAR_SHA256
```

Replace the placeholders with the authenticated 40-character commit and
64-character digest. Its parent directories must also be protected. On a trusted
release workstation, `git archive --format=tar "$revision" | sha256sum` computes
the digest for the reviewed commit. Authenticate that result separately before
approving it on the host. A checksum obtained from an untrusted download is not
publisher authentication.

The updater verifies the immutable source, backs up installed code, builds the
manager and Node, preserves configuration/data, and verifies readiness plus the
running revision before recording success. Calls and active connections can be
interrupted. If it fails, inspect the error and retained backup; there is no silent
rollback, identity replacement or success based only on the manager's version.

Private repositories need configured download credentials. The privileged manager
uses its protected token file, not an arbitrary caller environment. Do not paste
tokens into issue reports. If remote checking fails, verify repository access and
branch selection before changing the installation.

See [manual update recovery and offline transfers](loom-node-update-and-offline.md)
for an existing checkout or disconnected host. CI source bundles are not offline
Docker-image bundles, and this workflow does not provision fresh offline hosts.

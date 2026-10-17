# Run a Loom Home Node

Node Manager is the terminal interface for the installed Docker-based Home Node.
It operates your installation, not a hosted control panel. The first alpha uses
`0800x/Loom` as its source repository and `main` as its update channel.

## First installation

Follow [Home Node setup](node-setup.md) ([فارسی](node-setup.fa.md)). Paste the
single install command, enter your domain and select registration, federation
and calling options. Dependencies, HTTPS, storage, TURN and optional group media
are configured before Node Manager opens.

Run `loom` to return to the manager. Run `loom setup` to reopen the wizard using
the installation's verified source and existing choices as defaults. In
**Overview**, **Services** and **Network & TLS**, check readiness and public HTTPS.
Connect a client from another network using your public node page's QR/link,
approve its registration if required, then test messages and calls.

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

Official installations configure the **publisher** update policy automatically.
The manager reads the fixed `0800x/Loom` publisher channel over authenticated
HTTPS, validates its repository, immutable revision, SHA256 and increasing
sequence, and shows that approved source rather than every documentation or
bootstrap commit on `main`. It verifies the source archive before execution.
Only **Install update** installs it. The displayed selection stays fixed while
installation runs.

This policy trusts the project's GitHub account and HTTPS, just as the initial
installer does. Channel metadata is not a separately signed security audit.
TLS/download/validation failures stop the update; they do not select another
transport or source. Recorded publisher sequences prevent channel rollback.

A previous installation showing missing approval metadata can rerun the trusted
[Home Node installer](node-setup.md) once. It preserves existing configuration,
identity and data. `loom doctor` diagnoses startup separately; updating source is
not database-password recovery.

Operators who already maintain a private `/etc/loom/approved-releases` retain
that policy. In **operator** mode, each line is `0800x/Loom FULL_COMMIT_SHA
GIT_TAR_SHA256`, with the revision/digest independently authenticated and the
file root-owned mode 0600. `/etc/loom/update-policy` can contain `operator` to
select it. A missing approval is reported as **Source approval required**.
Do not disable source verification or copy a checksum from an untrusted artifact.

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

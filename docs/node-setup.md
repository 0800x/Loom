# Set up your Loom Home Node

Use a Linux VPS or server with root/sudo access, x64 or arm64, systemd and public
internet access. Start with 2 CPU cores and 4 GB RAM; group calls need more
capacity as participants increase. For public HTTPS, point a domain's **A record** directly to the
server's public IPv4. Disable a CDN proxy for this hostname. If an AAAA record
exists, its IPv6 address must also reach this server.

## Install

Connect over SSH and paste:

```bash
bash <(curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/0800x/Loom/main/install.sh)
```

The domain is the only required free-text answer. Use **Up/Down and Enter**
for the remaining choices; **Esc** cancels before installation. No option names
need typing. Use `--text` for line prompts on a basic terminal. The menus offer defaults:

| Question | Choices |
| --- | --- |
| Download sources | `official`, `liara` (Iran mirrors), or `arvan` (Arvan Docker/Ubuntu/Alpine, Liara Go/npm/Debian) |
| HTTPS mode | `public` for a public CA certificate; `local` for an explicitly trusted local certificate |
| Server address | Your hostname or IPv4 address, without a scheme, port or path |
| Registration | `approval` to review requests, `open` to allow sign-ups, `closed` to stop new registrations |
| Federation | `trusted` for approved peers, `disabled` for a standalone node, `open` for verified compatible peers |
| Voice calls | `auto` installs TURN, `manual` keeps an external relay, `off` disables calls |
| Video calls | `yes` or `no`, when calls are enabled |
| Group calls | `on` installs the media service, `off` disables it, `keep` preserves existing settings |

For local HTTPS, use a hostname resolvable by your devices or an IPv4 address. No public DNS or certificate issuance is required.

Review the summary and press Enter to install. Docker Engine/Compose,
PostgreSQL, attachment storage, HTTPS, the terminal manager and the selected
media services are provisioned for you. Credentials are generated privately;
there are no database passwords or TURN secrets to copy into a form.

The bootstrap contains a fixed source revision and two SHA256 pins. It verifies
the helper and complete source archive before privileged application setup.
Obtain this initial script through the project's trusted GitHub URL. For
independent source approval and offline preparation, see the
[deployment reference](../services/loom_server/deploy/README.md).

The install takes several minutes because it builds the server, manager and
[pinned storage service](../services/loom_server/deploy/STORAGE.md). Existing
MinIO binaries and storage formats are retained during a source update.
It stops on failed source verification, service startup or HTTPS validation.
Existing data, identity and valid service secrets are retained on reruns.
An unrelated web server or TURN service is never replaced automatically.

## Installing from Iran

The first menu selects **Official**, **Liara**, or **Arvan Docker + Liara Go/npm**. Arvan also supplies Ubuntu host and Alpine container package mirrors; Debian host packages use Liara.
The selected policy is saved for later setup and source updates. For unattended
setup, add `--downloads liara` or `--downloads arvan` to the installer arguments.
The default is `official`; no IP geolocation or silent mirror switching is used.

| Dependency | Liara profile | Arvan profile |
| --- | --- | --- |
| Docker Hub images, including build bases and call services | `docker-mirror.liara.ir` | `docker.arvancloud.ir` |
| Go modules | Liara Go proxy | Liara Go proxy |
| Node packages | Liara npm registry, with the committed dependency lock | Same |
| Alpine packages inside build/runtime images | Liara Alpine mirror | Arvan Alpine mirror |
| Ubuntu amd64 host packages | Temporary Liara APT sources | Temporary Arvan APT sources |
| Debian host packages | Temporary Liara APT sources | Temporary Liara APT sources |
| Docker Engine on Ubuntu and Debian 13+ | Signed distribution packages | Signed distribution packages |
| Other host distributions | Existing configured repositories | Existing configured repositories |

Docker mirror prefixes apply only to Loom image references. Setup does not edit
`/etc/docker/daemon.json`, restart Docker to change mirrors, overwrite host
repository files, or modify global Go/npm configuration. Ubuntu ARM64 uses
Ubuntu Ports, which this profile does not configure; set up a supported host
package mirror separately before installing. Package signatures, existing image
digests, archive hashes, TLS checks and Go checksum verification remain enabled.
Changing a tagged image's registry explicitly trusts the selected mirror for that
tag; a digest-pinned image must still match the original digest.

These profiles **do not provide a fully offline installation**. GitHub source,
uncached dependencies, the Go checksum service when needed, initial bootstrap prerequisites and public certificate issuance can still require international access.
A failed checksum never falls back to another source. If a selected mirror is
unavailable, installation fails; rerun setup and explicitly choose another profile.

Provider references: [Liara Go](https://docs.liara.ir/mirrors/go/),
[Docker](https://docs.liara.ir/mirrors/docker/),
[npm](https://docs.liara.ir/mirrors/npm/),
[Ubuntu](https://docs.liara.ir/mirrors/ubuntu/),
[Debian](https://docs.liara.ir/mirrors/debian/),
[Alpine](https://docs.liara.ir/mirrors/alpine-linux/), and
[Arvan Docker](https://www.arvancloud.ir/fa/dev/docker) and
[Arvan Linux repositories](https://www.arvancloud.ir/fa/dev/linux-repository).

## Choose a different Go mirror

Docker/APT and Go modules can use different providers. Both Iran download
profiles use Liara Go by default; selecting Arvan alone does not change Go.
If module downloads stall, rerun the verified installer with:

```bash
bash install.sh --downloads liara --go-mirror runflare
```

`--go-mirror` accepts `profile` (follow the download profile), `official`,
`liara`, `runflare`, or `goproxy-cn`. The choice is saved for future setup and
updates. It affects both Node Manager and the source-built storage service;
it does not edit global Go configuration or switch Docker/npm/APT sources.
Runflare documents `https://mirror-go.runflare.com`; Goproxy.cn documents
`https://goproxy.cn`. Neither is a guarantee of reachability from your server.

Storage builds now show module download requests separately from compilation.
Module downloads have a ten-minute limit. BuildKit caches verified modules and
compiled packages across interrupted builds, so retrying can reuse completed
work. Do not prune Docker build caches when recovering from a network failure.
Checksum verification remains enabled; no mirror switching follows a failure.
The compile phase uses downloaded modules with network module fetching disabled
and prints package names as it progresses. Compilation can still be slow on
small servers; a quiet interval alone does not establish a network failure.

Provider documentation: [Runflare Go mirror](https://runflare.com/mirrors/go-mirror/)
and [Goproxy.cn](https://goproxy.cn/).

## Linux distributions

Automatic package routes cover Ubuntu, Debian, Fedora, CentOS Stream, RHEL,
Rocky Linux, AlmaLinux, Arch/Manjaro and openSUSE/SLES. Use a maintained release
with working vendor repositories and Compose 2.24.4 or newer. Arch follows a full system upgrade when
installing missing packages. RHEL-family Docker uses Docker's official RPM
repository; subscriptions/repository access must already work on your host.
openSUSE uses its distribution packages. Older CentOS Linux releases and every
historical Linux version are not supported.

Docker, TLS and call media still need verification on each actual host. The
installer tests exercise package selection with command doubles; they do not
establish that every distribution has passed a complete live deployment.
Other distributions can reuse an existing functional Docker Engine/Compose
installation, with curl, Git, OpenSSL, `ss` and systemd available.

## Open the right ports

| Feature | Public inbound ports |
| --- | --- |
| Website, certificates, messaging | TCP 80 and 443 |
| Voice/video relay | TCP and UDP 3478; UDP 49160–49200 |
| Group-call media | TCP 7881; UDP 50000–50100 |

The installer updates active UFW/firewalld rules for selected services. In the
VPS provider's firewall/security group, allow the same ports yourself. Custom
nftables/iptables rules and router NAT forwarding remain under your control.
Database, object-storage administration and group-media TCP 7880 stay private.

## After installation

Node Manager opens automatically. Run `loom` whenever you want to return.
Arrow keys navigate; Tab changes focus; Enter selects; `?` opens help; `q` exits.

1. Open **Overview** and **Services** and check readiness.
2. Visit `https://YOUR_DOMAIN` from another network. Add this Home Node in Loom
   using the public page's link or QR code.
3. With approval registration, accept the account in **Registrations**.
4. Test messages and a call between two devices on different networks. Local
   STUN/TURN checks and an authenticated media API probe do not prove that your
   provider's firewall permits audio/video.

`trusted` federation does not automatically trust strangers. Use **Federation**
to verify and approve peers. Group-call media is independent of MLS group
membership; keep **Group calls** off if you only want text/media groups.

## Change settings and update

```bash
loom setup
loom
```

`loom setup` fetches the installation's exact verified source and reopens the
wizard. Existing choices are defaults. `manual` TURN retains operator-managed
credentials; configure them in **Calls → Configure TURN**. Invalid existing
secrets produce an error instead of silent replacement.

**Updates** checks the source channel automatically while the manager runs.
Review and select **Install update** to apply a publisher-approved revision.
The official installer configures that trusted HTTPS channel and protected
approval state automatically. Automatic checks do not mean unattended installation;
existing operator-managed approval policies are preserved. See
[Node Manager](node-manager.md) and [verified updates](loom-node-update-and-offline.md).

For a preview without changing services, download `install.sh` and run
`bash install.sh --plan`. A non-interactive installation can use:

```bash
bash install.sh --yes --domain chat.example.org --registration approval \
  --federation trusted --turn auto --video yes --group-calls on --no-manager
```

`chat.example.org` is an example; replace it with your actual domain.

## If setup stops

| Message or symptom | What to check |
| --- | --- |
| `curl: command not found` | Install curl through your distribution's package manager, then retry |
| Source checksum mismatch | Stop and obtain a fresh bootstrap from the trusted project URL; do not remove verification |
| No public HTTPS | DNS A/AAAA, CDN proxy, TCP 80/443, and any existing listener |
| Existing TURN service / port 3478 | Choose `manual` and configure the existing relay; auto setup will not take it over |
| Messages work but calls do not | TURN/group-media ports in both host and provider firewalls; **Calls** diagnostics |
| No systemd / unsupported CPU | Use a systemd Linux server with x64 or arm64 |
| Missing update approval metadata | Rerun the trusted installer once; existing operator policies are retained |
| PostgreSQL rejects its password | Restore the original `.env` matching retained database volumes; do not delete volumes or generate another identity |
| Existing volumes but missing `.env` | Restore the original configuration backup before installation can proceed |
| Module download returns `403 Forbidden` | The selected source is refusing this host. Rerun setup and select Liara or Arvan for an Iran server. Checksums remain mandatory; deleting data will not help |
| TUI closed | Run `loom`; exiting the manager does not stop the server |

Keep backups of Node identity, database, attachments and configuration. Do not
post `.env`, media configuration, recovery exports, tokens or raw signaling logs.

For a startup summary without changing services or printing secrets, run
`sudo loom doctor`. For an older manager without that command, the current
bootstrap supports `bash install.sh --diagnose` after downloading it from the
trusted project URL. This does not reset database credentials or recreate identity.

A normal uninstall retains Docker data and saves the matching private reinstall
configuration under `/opt/loom-backups/config-*`. Keep that backup private and
restore its `deploy/.env` before reusing retained volumes. Removing backups while
keeping data is rejected. A previous uninstall cannot retroactively recover
configuration that was already deleted.

## Local HTTPS and IPv4 addresses

Choose **Local** in the HTTPS menu, or pass `--tls local --domain 192.0.2.24`.
Replace the example IP with the server address reachable by your devices.
This mode uses Nginx, generates a 365-day certificate with an explicit DNS/IP
Subject Alternative Name, and verifies readiness with that exact certificate.
It makes no ACME request and does not silently fall back from public HTTPS.

The installer prints the SHA256 certificate fingerprint. Transfer only
`/opt/loom-node/deploy/tls-local/fullchain.pem` to the device through a trusted
channel. Never transfer `privkey.pem`. In Loom, open server selection, choose
**Import local HTTPS certificate**, compare the fingerprint with the server,
and explicitly confirm trust. Restart Loom before connecting. Use **Manage
local HTTPS trust** to remove a certificate; restart afterwards to release
existing TLS contexts. Existing older APKs do not have these controls.

Certificate trust does not bypass the Node's signed identity verification.
Hostname/IP checks, expiry and normal TLS validation remain enabled. Rerunning
setup preserves the certificate and private key. An expired certificate, a key
mismatch or a changed hostname causes an error instead of silent regeneration.
The normal private configuration backup includes local TLS material.

Native media playback, platform browsers and third-party call/media components
may require additional OS certificate trust; verify them on the target device.
Public federation peers also need their own explicit trust configuration.
For a standalone LAN, choose federation **disabled**. MLS text groups do not
require the group-call media service. Its current setup requires a public IPv4;
it is not advertised as an offline LAN conferencing server. Direct calls still
need live connectivity between devices, even when that connectivity is local.

## Automatic TURN

Select **Voice calls → auto** during installation. Setup installs the pinned
relay image through the selected Docker source, uses the server hostname/IP,
creates a strong shared secret only if none exists, opens supported host firewall
ports, configures STUN/TURN on the Node, and checks service readiness. Provider
firewalls and NAT still need the ports listed above. Keep the shared secret
private; clients receive short-lived call credentials from the Node.

After installation, **Calls → Set up TURN automatically** runs the same verified
setup for calls only; it does not rebuild the Node or replace a valid secret.
**Configure TURN** remains available for an operator-managed external relay.
An unrelated relay already using port 3478 is not stopped or replaced.

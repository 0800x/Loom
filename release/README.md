# Loom 0.1.0-alpha.1

The first public alpha includes the messenger, a self-hosted Home Node and its
terminal manager. Public download availability is shown on
[GitHub Releases](https://github.com/0800x/Loom/releases); CI artifacts are
available from [Actions](https://github.com/0800x/Loom/actions/workflows/loom-alpha.yml).

| Component | Version |
| --- | --- |
| Messenger | 0.1.0+28 |
| Node | 0.10.10 |
| Terminal manager | 0.8.6 |
| Desktop Node UI | 0.7.1+2 |

The public label is `0.1.0-alpha.1`. Component versions are checked independently.
See the [artifact matrix](ARTIFACT-MATRIX.md) for architecture and signing labels.
Each artifact manifest identifies its exact source revision. A build of an older
revision does not validate subsequent source changes.

The messenger supports English/Persian layouts, conversations, MLS groups,
media and multiple delivery paths. Home Node setup offers registration,
federation and calling choices, with automatic HTTPS and selected media services.
Start with [Home Node installation](../docs/node-setup.md).

Physical-device behavior, background delivery and real cross-network calls still
require validation on the target devices. Widget renders and isolated media
checks do not establish physical-device coverage.

## Compatibility

Application ID: `app.loom.messenger`; Node home: `/opt/loom-node`.
The alpha uses Loom protocol, discovery and recovery namespaces. It does not
silently import, delete or replace another application's identity or data.
Keep recovery exports; see [compatibility](../docs/compatibility.md).

GPLv3-only. Third-party code and assets retain their licenses and attribution.

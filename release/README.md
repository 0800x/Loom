# Loom 0.1.0-alpha.1

First public-alpha release preparation. `main` is the release source branch.
The source is available for testing. Native build validation and device acceptance
remain required before distributing signed application releases.

## Component versions

| Component | Version |
| --- | --- |
| Messenger | 0.1.0+28 |
| Node | 0.10.9 |
| Terminal manager | 0.8.4 |
| Desktop Node UI | 0.7.1+2 |

Mobile/desktop store metadata uses the numeric `0.1.0` client version with build
number 28. The public prerelease label is `0.1.0-alpha.1`. Existing Node/manager
version lines advance rather than decreasing to match the client.

## Included

- Independent Loom application and installation namespaces, supplied artwork.
- Shared messenger surfaces, media/composer polish and English/Persian layouts.
- Public node connection/status page and verified installation/update tooling.
- English/Persian README, maintained documentation index and Telegram channel.
- Scripted English mobile/desktop widget captures using fictional accounts.

## Checks and release gates

Fresh results and limitations are recorded in [VERIFICATION.md](VERIFICATION.md).
The messenger, design, server, native MLS and release-related package suites were
run locally; the full Go privilege-drop test remains blocked by this container.
Physical-device checks and the unbuilt messenger platforms are still release gates.

See [ARTIFACT-MATRIX.md](ARTIFACT-MATRIX.md) for signing/architecture labels and
[APPROVAL-CHECKLIST.md](APPROVAL-CHECKLIST.md) for the exact approval/tag/draft sequence.
No source label, workflow configuration or widget screenshot establishes that a
native distributable has been built. No tag or public release was created.

## Compatibility

Application ID: `app.loom.messenger`; Node home: `/opt/loom-node`; source checkout:
`/opt/loom-src`. This is a separate app installation. Existing data is not silently
imported, deleted or replaced. Keep recovery exports before removing another app.
The public alpha uses the Loom namespace across protocols, discovery, recovery
containers and protected envelopes. This is a breaking change; see
[compatibility](../docs/compatibility.md). Key derivation and signing identities
remain unchanged.

Loom uses GPLv3-only. Third-party code and assets retain their licenses.

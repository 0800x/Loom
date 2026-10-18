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

## Signed release process — required, not yet operational

`release/version.json` remains `published: false`. A source PR or an engineering
artifact does not establish a signed public release. Before changing that flag:

1. Review an exact immutable commit, run all relevant CI and physical acceptance,
   and generate an SPDX/CycloneDX SBOM plus dependency/license inventory.
2. Build on isolated pinned toolchains. Record source revision, workflow identity,
   build inputs and artifact digests in SLSA-style provenance; independently
   rebuild/compare where practical. State any nondeterministic differences.
3. Generate SHA256SUMS covering every archive, installer, SBOM and provenance file.
   Sign the manifest and bootstrap installer using a separately held minisign key
   (or cosign with a documented OIDC issuer/identity policy). Never commit a secret
   signing key. Android must retain its existing protected production keystore.
4. Publish the verification public key and fingerprint through an independent,
   authenticated channel. Document key custody, revocation/rotation and recovery.
   A key shipped only beside the artifact does not authenticate that artifact.
5. Attach exact files and signatures to a tag, verify them from a clean client,
   and bind update metadata to that reviewed revision/digest and monotonic release
   sequence. Test rejection of modified files, wrong key/identity and rollback.
6. Only then mark the release published. Keep unsigned engineering outputs clearly
   labeled; platform signing/notarization and source signatures are different gates.

Example verification after the publisher has actually supplied signed assets:

```bash
# Set these from independently authenticated release information.
: "${LOOM_RELEASE_TAG:?set an exact signed tag}"
: "${LOOM_PUBLISHER_KEY:?set the verified minisign public key}" # gitleaks:allow -- public verification key placeholder
curl --proto '=https' --tlsv1.2 -fLO "https://github.com/0800x/Loom/releases/download/$LOOM_RELEASE_TAG/SHA256SUMS"
curl --proto '=https' --tlsv1.2 -fLO "https://github.com/0800x/Loom/releases/download/$LOOM_RELEASE_TAG/SHA256SUMS.minisig"
minisign -Vm SHA256SUMS -P "$LOOM_PUBLISHER_KEY"
sha256sum --check SHA256SUMS
```

The example describes the required distribution contract; it does not claim those
assets, publisher key publication, SBOM/provenance signing or reproducibility
already exist. Verify before executing any downloaded installer.

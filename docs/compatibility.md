# Loom protocol compatibility

The first public alpha uses the Loom wire namespace. This is a deliberate breaking
change from earlier internal builds. It changes authenticated bytes, not only
screen labels.

| Boundary | Current format |
| --- | --- |
| Server discovery | `/.well-known/loom/server` |
| Federation | `loom-federation-v1`, `X-Loom-*` headers |
| Device requests | `X-Loom-*` headers and Loom canonical proof domains |
| Direct and group messages | Loom protocol tags and associated-data domains |
| Device linking | `loom-device-link:` QR and `loom-device-link-v2` envelope |
| Nearby | Loom discovery, rendezvous and bearer handshakes |
| Plain recovery file | `loom-recovery`, version 1 |
| Encrypted recovery file | `Loom-Recovery-v1` |
| Protected credentials | `loom-protected-v1:` |

The exact implementation domains are listed in
[the protocol contract](../release/compatibility-contract.json). All participating
clients and nodes must use the same namespace. An authentication failure is not
retried through an unauthenticated fallback.

## Existing installations

Use a separate test installation for this alpha. Export data with the original
application before changing software. Earlier recovery containers, sealed MLS
state, protected vaults and encrypted conversation history are not automatically
converted. The installer ownership marker also changes; the new installer must
not take over an earlier installation implicitly.

A protected value with an unsupported envelope is rejected before it is returned
or wrapped again. Keystore errors preserve the storage contents. No code path
creates a replacement account identity to recover from those failures.

## Identity and signing keys

The 24-word entropy-to-Ed25519 derivation is unchanged. The same valid words
produce the same public key, fingerprint and identity identifier. A raw phrase
can be restored explicitly after validating its checksum. Exporting/importing a
file uses the new container and authenticated format.

Application IDs and signing configuration are unchanged. Builds use existing
production signing keys when supplied; no workflow manufactures a replacement
key. Unsigned engineering APKs cannot be installed as distributed.

## Release checks

Server and client tests cover matching namespace delivery and rejection of
unsupported proofs, recovery formats and protected envelopes. Native MLS tests
cover sealing, restore, tampering, replay, membership and call exporters. Hardware
acceptance remains necessary for media, calls and Android radios.

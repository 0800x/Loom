# Loom alpha threat model

Scope: shipping legacy direct messages, MLS groups, Home Node delivery,
federation, Android Nearby carriers, local persistence, installation and updates.
The vodozemac session provider is experimental and disabled for production sends.
No independent audit, physical-device matrix completion or signed-release chain
is implied by this document. Distinguish message confidentiality, authenticated
identity, metadata privacy, device privacy and availability.

| Adversary | Assets / attack | Controls and residual risks |
| --- | --- | --- |
| State-level censor | Block/throttle/DPI links, correlate flows, compel operators | HTTPS and multiple verified routes protect some content/authentication. Endpoints, IPs, timing, size and availability remain observable. Whitelisting all reachable paths can prevent delivery; DTN needs actual compatible encounters. |
| Malicious Home Node | Directory substitution, replay, drop messages, harvest metadata | Device/account signatures, signed discovery and E2EE are checked on endpoints. A node can withhold data and sees social graph, timestamps, IPs, group membership and encrypted attachment sizes. Backups and operator compromise expose this metadata. |
| Malicious federated node | Spoof origin, flood queues, replay/discovery SSRF | Signed envelopes, peer policy, address validation, replay store, safe HTTPS and quotas. OPEN admits unblocked verified identities, not trustworthy humans; Sybil peers and traffic correlation remain possible. |
| Malicious Nearby carrier | Drop/duplicate packets, forge custody, exhaust disk/radio | Authenticated peer links, opaque packets, TTL/hop/copy checks and receipt semantics. Custody is not recipient delivery; malicious peers can refuse forwarding. Per-peer admission and physical radio-abuse tests must not be inferred from routing pressure thresholds. |
| Seized/unlocked device | Read messages, capture recovery words, extract state | Platform secure storage, optional App Lock, secure Android windows and generic public notifications. Unlocked device/OS compromise, accessibility, external cameras and exported plaintext recovery remain dangerous. Non-Android screenshot behavior differs. |
| Compromised update channel | Supply malicious source/binary or rollback | Immutable revisions/digests, authenticated approvals, preserved signing keys and fail-closed install checks help. Initial moving bootstrap, unpinned artifacts, compromised publisher keys and missing independently verified release signatures remain separate risks. |

## Cryptographic limits

Shipping Loom-Direct-v1 is per-device sealed-box encryption to long-term X25519
keys, not a ratchet. Later compromise of a recipient's long-term agreement key
can expose previously captured ciphertext. It provides neither ratchet forward
secrecy nor post-compromise security. Public-key-derived relay tags can be
recognized by parties knowing the public key; outer signatures may provide
transferable evidence. ADRs propose migration without changing shipped crypto.

MLS currently requires same-Home-Node membership coordination and an online admin
device for joins. Recovery words do not reconstruct lost ratchet state. Native
FFI memory safety and provider composition require review beyond library choice.

## Trust boundaries and operations

Recovery files/QRs may be plaintext after warning. Passwords do not replace the
random 24-word identity entropy. Imported local HTTPS trust is restricted to an
explicitly confirmed origin and leaf; it is not an account identity proof.

Rate quotas are process-local except durable queue admission serialization.
Saturation may reject legitimate traffic. Existing messages are not deleted to
manufacture room; delivered history, attachments, logs and backups need monitored
storage/retention policies. No transport can promise access through a complete
network whitelist or guarantee message delivery before expiry.

## Release gates

Track each finding as VERIFIED/REFUTED/UNCONFIRMED with exact revision evidence.
Execute hostile-peer/disk-pressure, permission, Doze/OEM, native ABI and all target
platform tests. Complete transitive attribution review and signed release key
custody/reproducibility. Independent review remains an external gate, not a box
that source edits or a CI badge can close. See SECURITY.md for private reporting.

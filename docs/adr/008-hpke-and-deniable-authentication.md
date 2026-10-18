# ADR C4/C5: standard KEM context and deniable authentication (design only)

Status: proposed. No HKDF info, AAD, signatures or ciphertext bytes are changed.

The current relay seal's HKDF info is the associated-data context rather than a
standard HPKE transcript binding ephemeral and recipient public keys into the KEM
context. Do not infer an exploitable attack solely from that difference. Propose
replacing the composition with an existing reviewed RFC 9180 HPKE implementation
and explicit suite, mode, key serialization, labeled extract/expand and KEM context.
Do not manually copy selected HPKE formulas into legacy encryption.

Specify recipient/device binding, sender authentication mode, AAD serialization,
malformed-key rejection, encapsulation reuse limits and test vectors. A new wire
version is required: changing derivation breaks decryption of existing messages.
Implement dual readers only under explicit version selection; no fallback after
authentication failure. Test standard vectors, wrong recipient/context, malformed
encapsulation, mutation, cross-version confusion and persisted retry equality.

Ed25519 outer signatures can produce transferable evidence tying ciphertext to
a signing key; encryption does not make such signatures deniable. A recipient or
relay may retain them. Whether that establishes a real-world identity depends on
external evidence; do not promise legal or social deniability.

For ratcheted v2 evaluate the authentication/deniability properties of the chosen
reviewed protocol as a whole. Avoid persistent outer identity signatures on every
message if deniability is a product goal; consider session-authenticated envelopes
and authenticated routing credentials with minimized public evidence. Account
and device-directory authorization may still require durable signatures. MLS
group signatures and operator logs are separate boundaries, not automatically
made deniable by changing direct messages.

Decide recipient authentication, abuse reporting and transcript-evidence tradeoffs
with the maintainer and independent reviewers before implementing. Test replay,
unknown-key-share, impersonation, sender revocation and cross-session confusion;
document what a malicious recipient can prove or fabricate. Never claim perfect
deniability against endpoint compromise, screenshots or external recordings.

Reference: RFC 9180, Hybrid Public Key Encryption, https://www.rfc-editor.org/rfc/rfc9180

# Loom federation security model

Security is a merge gate for federation. Functional delivery is not considered complete if it weakens Node identity, account/session authentication, or end-to-end encryption.

## Trust boundaries

Loom has three separate trust boundaries. They must not be collapsed into one another:

1. Node ↔ Node: authenticates federation infrastructure and routing metadata.
2. Client ↔ Node: authenticates the user's Home Node and the user's device/session to that Node.
3. Client ↔ Client: authenticates user/device cryptographic identities and protects message plaintext end to end.

A valid Node signature does not authenticate an end user. A valid user session does not make a Node trusted for federation. A trusted federation Node does not receive permission to decrypt client ciphertext.

## Node ↔ Node invariants

For public federation:

- Federation uses HTTPS only.
- Discovery starts from the domain in the Loom address and fetches the signed discovery endpoint defined in `src/federation/discovery.ts` from that same domain.
- Redirects are rejected.
- Discovery responses are size limited and time limited.
- The advertised endpoint authority must match the requested Loom domain.
- The Ed25519 discovery signature must verify.
- `nodeId` must be derived from the advertised public key; a self-consistent signature with an unrelated Node ID is rejected.
- Node identity changes are not silently accepted over an existing cached/trusted identity.
- Discovery and operator trust are separate states.
- `TRUSTED` requires explicit operator trust for sensitive federation operations.
- `OPEN` accepts cryptographically valid compatible Nodes, but still performs every identity/signature check.
- `LOCAL` and the local side of `HYBRID` are determined from the verified advertised endpoint, never from the reverse-proxy TCP source address. Caddy/Nginx/Docker source addresses must not turn public traffic into local federation traffic.
- Public discovery rejects private/loopback/link-local destinations to reduce SSRF exposure.
- Federation requests reject redirects and use bounded timeouts and response sizes.
- Event envelopes are signed by the origin Node and bind origin/destination Node IDs, origin/destination domains, sender, recipients, conversation, event ID, event type, timestamp, and opaque payload.
- Inbound events validate protocol version, signature, destination, sender/origin relationship, recipients, timestamp and payload limits before persistence.
- Inbound `eventId` tracking provides replay/duplicate suppression.
- Outbound transport is at-least-once; inbound processing is idempotent.

DNS is routing input, not an identity credential. DNS success alone never establishes Node trust.

## Client ↔ Node invariants

Before a client treats a Home Node as freshly verified:

- Public endpoints must use HTTPS.
- The signed well-known document is verified with Ed25519.
- The discovery endpoint must remain on the requested authority.
- The Node ID must be derived from the discovery public key.
- Registry-selected Nodes additionally pin the registry Node ID/public key/fingerprint.
- Live Node metadata must report the same Node ID as discovery.
- A saved session is only a **pin**, not proof that the Node currently serving the endpoint is the same Node.
- Before the app loads/sends a refresh token, it performs fresh discovery, compares the Node ID/public key/fingerprint with the saved pin, and sends a random nonce to `/api/v1/server/challenge`.
- The challenge response must echo the nonce and Node ID and carry a valid Ed25519 signature from the pinned Node key.
- If discovery, pin comparison, or challenge verification fails, the account remains offline and the refresh token is not sent.
- Password login and registration perform the same Node key-possession challenge immediately before credentials are submitted.

Secrets:

- Passwords are transmitted only to a freshly verified Home Node over an acceptable transport.
- Access tokens are short-lived bearer credentials and must never be logged.
- Refresh tokens are stored in platform secure storage and must never be stored in ordinary application preferences/databases.
- Server-side session tokens are stored hashed.
- Node/admin/session tokens are never exposed through federation APIs or diagnostics.
- Private identity/device keys remain in platform secure storage on the client.

### Implemented device-bound request proofs

Ordinary authenticated client routes call `LoomNodeServer.authenticated()`, which
validates the bearer session, account/device quotas and `DeviceRequestVerifier`.
The Ed25519 proof signs the versioned `Loom-Device-Request-v1` canonical domain,
method, exact path/query, body SHA-256, timestamp, nonce, device ID and credential
SHA-256. The timestamp window is ±2 minutes. GET/HEAD require the empty body
hash; JSON readers compare the declared digest with the bytes actually read.

Replay nonces are stored durably per device for 10 minutes in
`device_request_nonces`. Expired entries are deleted when admitting a new nonce;
there is no independent periodic cleanup job. Restart does not clear live nonce
history. See `src/security/device_request_proof.ts`,
`src/security/device_bundle_store.ts` and `test/device_request_proof.test.ts`.

The initial PUT to the session's own device-key-bundle endpoint is exempt from
request proof only while no registered signing key exists. Publication still
checks account/device ownership, revocation, device signature and account identity
signature. A different key cannot silently replace an existing bundle.
See `test/device_bundle_security.test.ts`.

Password login/registration, refresh and device-link redemption bootstrap, admin
bearer APIs, signed federation requests and self-certifying direct/gateway ingress
use their respective authentication boundaries; they are not ordinary
registered-device request-proof routes. The delivery adapter uses the same
`authenticated()` callback for its session routes. All HTTP routes now pass
through common IP/class/credential/concurrency admission before adapter dispatch.
These implemented controls do not constitute an independent security audit.

## Client ↔ Client invariants

Loom user identity and device identity are separate layers:

- Long-term user identity uses Ed25519.
- Each device has its own Ed25519 signing key and X25519 agreement key.
- A device bundle is self-signed by its device signing key.
- The same canonical bundle is signed by the user's long-term identity key.
- Clients verify the bundle fingerprint, device self-signature, identity binding, identity ID and key sizes before using a remote device key.
- Safety-number / QR verification is derived from both users' identity and device public material.
- Remote key changes must not silently overwrite previously verified client trust state.

Message plaintext is encrypted/decrypted on clients. Nodes and federation transport route opaque ciphertext. Federation must not add a server-side decryption step or export client private keys.

For federated lookup, a remote Node may return only federation-safe public profile/cryptographic material required to address and encrypt to the user. Passwords, password hashes, sessions, refresh/access tokens, recovery material, private identity keys and private device keys are forbidden.

## Data visibility

| Data | Sender client | Sender Node | Federation transport | Recipient Node | Recipient client |
| --- | --- | --- | --- | --- | --- |
| Message plaintext | yes | no | no | no | yes |
| Message ciphertext | yes | yes | yes | yes | yes |
| Canonical sender/recipient addresses | yes | yes | yes | yes | yes |
| Public identity/device keys needed for E2EE | yes | cache/public only | lookup response only | public only | yes |
| Client private identity/device keys | yes | no | no | no | yes |
| Password/session tokens | client/Home Node only | Home Node only | no | no | no |

## Failure policy

Security validation failures fail closed. They are not retried as ordinary transient delivery errors when the failure is permanent, including invalid signatures, protocol mismatch, identity/key mismatch, invalid destination/recipient, blocked trust state, oversized payloads, and malformed envelopes.

Temporary network failures keep already-authenticated local state intact and leave remote delivery in the durable outbox for bounded retry. An offline Node must never cause plaintext fallback, trust bypass, identity replacement, or silent message loss.

## Merge security gate

Before this branch is recommended for merge, automated tests must cover at least:

- changed Node key / Node ID mismatch;
- bad discovery, challenge and federation event signatures;
- discovery endpoint mismatch;
- public-to-private SSRF attempts and DNS-rebinding-sensitive fetch behavior;
- reverse-proxy source address not bypassing LOCAL/HYBRID policy;
- stale handshake/event timestamps;
- replay and duplicate event delivery;
- blocked/trusted/open policy behavior;
- client Home Node key pinning and re-verification before password/refresh-token use;
- device-bound authenticated request replay/signature checks;
- remote identity/device bundle signature validation;
- remote identity/device key-change warning/fail-closed behavior;
- proof that federated Node code receives only ciphertext for an encrypted direct message.

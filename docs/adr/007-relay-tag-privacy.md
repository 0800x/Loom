# ADR C3: relay tag unlinkability (design only)

Status: proposed; existing derivation unchanged.

`relay_sealing.dart` computes an 18-byte truncated SHA-256 recipient tag from a
public label, recipient static X25519 key and a six-hour epoch. Rotating a tag does
not make it secret: anyone knowing that public key can calculate current/nearby
epoch tags and recognize the recipient's traffic at cooperating relays. A censor
or malicious contact can retain observed tags for retrospective correlation.

Evaluate tags derived from a per-contact shared routing secret under an existing
reviewed KDF; require authenticated secret establishment/rotation, separate domains
from encryption keys, and explicit device/contact revocation. Relay matching then
needs a mailbox token distribution design without exposing contact secrets to the
Home Node. Enumerating all contacts' tags may reveal social graph and consume
battery/storage, especially for store/carry/forward. Multi-device and offline
bootstrap cannot assume an online directory at every encounter.

Evaluate blinded rendezvous/token schemes only through a standard protocol with
independent review, including abuse quotas, Sybil resistance and linkability of
blinding/unblinding. Consider overlapping short rotation windows for skew/delayed
DTN packets, with bounded acceptance and durable tombstones; shorter rotation
alone does not fix public-key precomputation.

A protocol-versioned migration and no-downgrade policy must precede new tags.
Legacy packets retain their documented leak; do not advertise them as anonymous.
Residual leakage includes packet sizes, route/encounter timing, carrier presence,
mailbox polling, gateway traffic, IP addresses and global observation. Tests must
measure candidate-tag recognition by a malicious contact, epoch overlap/replay,
revocation, multi-device routing and resource bounds during extended offline use.

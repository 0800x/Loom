# ADR: imported TLS leaf certificates are bound to an HTTPS origin

Status: accepted, 2026-10-18 security completion.

Never mutate SecurityContext.defaultContext. Store an explicit HTTPS host/port,
confirmed SHA-256 leaf fingerprint and public PEM in an origin-named binding.
Native X509 parsing plus ASN.1 BasicConstraints parsing rejects CA:TRUE and
certificates without an explicit BasicConstraints extension. System-trusted
HTTPS continues normally; a failed handshake is accepted only for the exact
confirmed leaf and origin within its validity dates. Redirects to other origins
receive no exception. No downloaded certificate is automatically imported.

Revoking a binding closes tracked clients that used that pin and removes it from
future handshake decisions. Tracking is bounded to 256 weak client references;
capacity fails closed. This does not replace signed Home Node discovery or device
proofs. Other native/plugin TLS stacks do not inherit this Dart pin policy and
must still use ordinary trusted PKI; no native global CA installation occurs.

Compatibility: old unscoped PEM files are rejected on load and require explicit
host/fingerprint confirmation again. New origin JSON files do not change message,
identity or recovery formats. Downgrading to old binaries loses scoped pin support;
do not restore their former process-wide trust behavior. Certificate trust can be
removed in server selection; forgetHost is the removal boundary for any future
server-deletion action (the current directory has no persistent delete action).

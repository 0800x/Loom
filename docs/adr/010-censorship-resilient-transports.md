# ADR G5: transport reachability under censorship (design only)

Status: proposed; no transport implementation or bypass guarantee.

Evaluate Tor SOCKS routing and maintained pluggable transports (such as obfs4 or
Snowflake) through their supported interfaces, with explicit user choice and
credential/DNS/proxy leak tests. Distinguish service reachability from anonymity:
Home Nodes still see authenticated account activity, and global traffic analysis
or a seized device may defeat privacy goals. Bridge distribution and blocked
bootstrap are operational dependencies, not solved by listing Tor as an option.

Evaluate multiple independently hosted Home Node endpoints bound to the same
verified node identity. Endpoint rotation requires authenticated authorization,
sticky identity pins, revocation and bounded retries; never treat certificate or
identity failure as permission to try an unauthenticated endpoint. Measure delay,
battery use and metadata concentration when using parallel paths.

CDN deployment must follow the provider's supported WebSocket/HTTP behavior and
terms. Domain fronting is frequently unsupported or blocked; do not assume that
changing SNI/Host creates a usable route. Require explicit provider support and
review identity, TLS termination and traffic correlation. Ordinary TLS, Tor and
CDN transports can all be blocked, throttled or fingerprinted.

During a network whitelist blackout, if no authorized reachable endpoint or
compatible local/carrier path exists, there is no IP-layer trick that guarantees
external connectivity. ARP is link-local and cannot discover a server across
unrelated routed networks. DTN can preserve encrypted packets until actual
encounters within expiry but cannot manufacture encounters or live calls.

Test domestic/global reachability separately, DNS poisoning, active probes,
blackholed TCP/UDP, MTU/fragmentation, proxy-auth loss, background/Doze behavior,
clock skew and zero available routes. Preserve exact queued ciphertext and honest
Queued/Accepted/Delivered semantics; never fabricate delivery to hide censorship.

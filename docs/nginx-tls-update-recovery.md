# Preserve Nginx HTTPS during Node updates

The operator's update built and started the Node containers, then failed because
another Certbot process held its lock. The installer had already replaced the
Loom HTTPS virtual host with an HTTP-only 503 bootstrap. Other active Nginx
sites could then answer SNI requests with an unrelated certificate.

Reuse a locally valid hostname-matching certificate before writing any HTTP-only
bootstrap. Keep the renewal hook/timer enabled. If issuance fails but a concurrent
issuer has supplied a valid certificate, configure HTTPS using it. Reject
successful issuance that does not produce a valid hostname-matching certificate.
Report Certbot concurrency separately from DNS/challenge errors.

Validation: six regression tests pass, including real OpenSSL certificates,
hostname mismatch, missing private-key file, reuse without issuance/HTTP
downgrade, failed issuance, invalid issued certificate, and concurrent issuance.
The Bash installer passes syntax validation. No production SSH, live Nginx reload
or public endpoint verification was available here. The operator must rerun the
pinned installer and verify the public certificate and readiness.

# Security policy

Loom is an unaudited alpha. Do not rely on it as the sole protection for a
high-risk identity or irreplaceable information. Only the current alpha branch
is supported on a best-effort basis; no stable/LTS security support is promised.

Report privately to **0800x@atomicmail.io**, the pseudonymous maintainer contact
already recorded in repository history. Include affected revision/platform,
minimal reproduction, impact and a proposed fix if available. Do not send recovery
words, production credentials, private conversations or live exploit targets.
GitHub private vulnerability reporting may also be used if enabled in repository
settings; do not open a public issue with exploit details if it is unavailable.

Response targets (not an on-call SLA): acknowledge within 7 days, initial triage
within 14 days, and agree a remediation/disclosure timeline, normally within
90 days. Critical active exploitation may require earlier coordinated disclosure.
No guaranteed response or patch deadline can be offered by a volunteer project.
If email fails, request a private contact through a public issue without details.

The threat model and remaining platform/release gates are documented in
[docs/threat-model.md](docs/threat-model.md) and the audit reports. Passing CI is
not an independent audit or proof of safe use under state-level surveillance.

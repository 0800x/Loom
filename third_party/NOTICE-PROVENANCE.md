# Recovered upstream notices

The 2026-10-18 follow-up resolves the ten previously missing notice entries.
`upstream-license-sources.json` records immutable source URLs; the original bytes
are stored under their SHA-256 filenames. Retrieved Git blob contents were also
checked against their upstream Git blob IDs before preservation.

- crabgrind 0.2.6 and 0.3.1: commits
  `30cf77b1ca50df3b940346000634e66ed1d5c259` and
  `ea38389bdf0731866d812352c11a921c6c657d5d` have the identical LICENSE tree
  `85ca254f6ea972c2f3fa9801eeea97b79ff53bec`. Preserve all eight texts,
  including the Valgrind header notices, rather than just MIT.LICENSE.
- r-efi 6.0.0: its AUTHORS file contains the actual license grants and copyright
  notices. It has no standalone LICENSE file. Preservation does not select or
  change any upstream dual/triple license choice.
- pg-types 2.2.0 and pgpass 1.0.5: the complete upstream README files contain
  their MIT grants and copyright notices; do not substitute generic MIT text.
- protobuf 1.10.1 and xterm/headless 6.0.0: preserve their upstream LICENSE files.
- AWS credential-provider-http 3.972.76, credential-provider-login 3.972.81 and
  nested-clients 3.997.48: all three versions are declared in upstream commit
  `3e350b59848e2bffcfe4d34a628e7adc136a6a55`, under `packages-internal/`.
  The published nested-clients repository.directory field still says packages/;
  following that stale field produces a 404. Preserve the repository Apache-2.0
  LICENSE at that immutable commit (blob
  `0322cba2eac898acb5c8577a20657e7a74af55a4`). This establishes the notice
  source, not byte-for-byte equivalence between a generated npm bundle and source.

`generate-third-party-notices.py --from-inventory` preserves existing metadata
when dependency caches/toolchains are unavailable. Full generation still requires
all dependency caches to be installed as documented in the generator. Both paths
verify fallback text digests. CI rejects missing texts and changes from re-rendering
the preserved inventory. Native platform binaries, codecs, fonts, assets and final
distribution obligations still require release-specific review.

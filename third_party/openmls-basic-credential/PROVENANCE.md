# Vendored OpenMLS Basic Credential

This directory contains the `openmls_basic_credential` crate from the
[openmls/openmls](https://github.com/openmls/openmls) repository, pinned to
commit `28369d5b48608bef4ddf8371d91503b0f3852bb3`.

The crate keeps the upstream package version `0.6.0` and the same public
credential/signing/storage API. Its manifest is standalone and retains the
published OpenMLS traits version `0.6.0`, while using the upstream-fixed
RustCrypto `p256` and `p384` `0.14` dependencies. This prevents the older
published credential crate from reintroducing `crypto-bigint 0.5.x`.

The source is covered by the upstream MIT license in `LICENSE`. The only
intended manifest adjustment is removal of workspace-only/dev-only entries;
the production source is the pinned upstream file.

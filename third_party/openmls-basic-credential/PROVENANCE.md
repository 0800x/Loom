# Vendored OpenMLS Basic Credential

This directory contains the `openmls_basic_credential` crate from the
[openmls/openmls](https://github.com/openmls/openmls) repository, pinned to
commit `28369d5b48608bef4ddf8371d91503b0f3852bb3`.

The crate keeps the upstream package version `0.6.0` and the same public
credential/signing/storage API. Its manifest is standalone and retains the
published OpenMLS traits version `0.6.0`, while using the upstream-fixed
RustCrypto `p256` and `p384` `0.14` dependencies. This prevents the older
published credential crate from reintroducing `crypto-bigint 0.5.x`.

The source is covered by the upstream MIT license in `LICENSE`. The standalone
manifest removes workspace-only/dev-only entries and adds the `maybe-async`
macro dependency. Three `#[openmls_traits::maybe_async]` attributes are
rewritten to the equivalent `#[maybe_async::must_be_sync]` because the
published `openmls_traits` 0.6.0 crate does not re-export that macro. Loom's
MLS adapter is deliberately sync-only, and its `openmls_traits` dependency
uses the default sync mode. No credential serialization format or public
method signature is changed.

# Vendored OpenMLS Rust Crypto provider

This directory contains the OpenMLS RustCrypto provider from upstream repository
[openmls/openmls](https://github.com/openmls/openmls), pinned to commit
`28369d5b48608bef4ddf8371d91503b0f3852bb3`.

The provider source is kept at upstream revision `0.6.0` while its dependency
manifest is made standalone for this repository. Its OpenMLS trait and memory
storage dependencies remain the published `0.6.0` crates used by this project.
The upstream `p256` and `p384` dependencies are `0.14`, avoiding the
vulnerable `crypto-bigint 0.5.x` dependency reported by the security audits.

The vendored source retains the upstream MIT license in `LICENSE`.
No changes are made to Loom's MLS protocol API or to its configured OpenMLS
version. Cargo's lockfile and CI tests remain the authority for dependency
resolution and compatibility.

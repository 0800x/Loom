# Loom artwork

The canonical artwork is supplied by the owner in `loom_brand_assets(1).zip`.
`SOURCE.txt` retains its original description. `loom-launcher-color.svg` is the
launcher source; `loom-light.svg` supplies the light-surface variant.

With `sharp` available, run `node scripts/generate-client-icons.cjs` from the
repository root. It regenerates Flutter brand images, Android launcher,
notification and splash artwork, iOS/macOS icons, Windows icons, Linux launcher
artwork, README and server artwork. Keep the supplied vectors and ICO checked in.

The mark is displayed with contain fitting and theme-aware contrast in Flutter.
Historical UI evidence is not a current branding preview. Native platform builds
and rendered Flutter screens must be checked on machines with their SDKs.

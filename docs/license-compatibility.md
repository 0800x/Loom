# License compatibility and provenance

Loom remains GPL-3.0-only. Dependency code, notices and copyright retain their
own licenses; a namespace rename does not transfer authorship. THIRD_PARTY_NOTICES
is generated from locked dependencies and installed upstream notice texts. Review
all missing declarations/texts, native plugin transitive dependencies, bundled
media codecs, fonts and assets before distributing a final signed binary.

Do not infer compatibility from a package's name or popularity. MIT/BSD-style
notices must be retained; Apache-2.0 notice/patent requirements still apply when
combined with GPLv3. The FSF and Apache Foundation describe Apache-2.0 as compatible
with GPLv3 (not GPLv2-only); exact obligations depend on the actual license text.
Noncommercial, unknown or custom licenses require individual review. Dual license
choices must be recorded explicitly rather than silently relicensing upstream.

GPLv3 distribution must not impose incompatible additional restrictions. Apple
App Store terms, signing/DRM and installation constraints need separate review;
there is no blanket claim this GPL-3.0-only application can be submitted there.
Do not promise an App Store release or add a license exception without permission
from all relevant rights holders. Ad-hoc macOS builds are not App Store clearance.

Primary references:
- https://www.gnu.org/licenses/gpl-3.0.html
- https://www.gnu.org/licenses/gpl-faq.html
- https://www.gnu.org/licenses/license-list.html
- https://apache.org/licenses/GPL-compatibility.html
- https://developer.apple.com/support/terms/

Vendored Android audio/record/video forks retain their LICENSE files and upstream
provenance. Compare their actual source history when assessing rename provenance;
this generated inventory cannot prove authorship of every historical line.

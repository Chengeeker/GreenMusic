# Third-party notices

GreenMusic adapts QQ Music protocol and business logic from **Lilt**,
https://github.com/Amamiya23/mygo-qyin at c407d97c96fb13e75b4197994c6b145e44bf9dc3,
licensed under GNU AGPL version 3. The original license is included in LICENSE
and the reference snapshot is under vendor_reference/lilt.

Material 3 UI components, theme and haptic feedback are copied/adapted from
**Review**, https://github.com/Chengeeker/Review, local source 3.14.0+238.
Review's MIT license is retained in docs/REVIEW_LICENSE.

Lilt's upstream third-party notices remain in vendor_reference/lilt/THIRD_PARTY_NOTICES.md.
Flutter dependencies retain their respective licenses and are available from
the application's license page.

Notification transport, shuffle and repeat icons use **Google Material Icons Round**,
https://github.com/google/material-design-icons, under Apache-2.0.
The license is retained in docs/MATERIAL_ICONS_LICENSE and the app's license page.

The M3 now-playing layout in 1.0.10 uses design references from **OuterTune**
(https://github.com/OuterTune/OuterTune, GPL-3.0) and **Retro Music Player**
(https://github.com/RetroMusicPlayer/RetroMusicPlayer, GPL-3.0). Their screenshots,
Compose/XML layouts informed the visual hierarchy; their artwork, Android
implementation and media backends are not bundled. Flutter widgets and the existing
Review components implement the GreenMusic player.

Review's personalization, icon picker, display-mode selector, WebDAV form and
backup transport workflow are also copied/adapted in 1.0.1. Music data schema,
secure credential storage, stricter endpoint validation and Android integration
are adapted for GreenMusic; source hashes are in docs/REVIEW_SOURCE.json.

The local **liquid_glass_widgets** 1.13.0 package is copied from Review's bundled
package, originally https://github.com/sdegenaar/liquid_glass_widgets,
copyright 2024–2026 Sebastian Degenaar, MIT. Its LICENSE and THIRD_PARTY_NOTICES
are retained in packages/liquid_glass_widgets. The shader loader is modified to
use dependency-namespaced assets during app-level widget tests.

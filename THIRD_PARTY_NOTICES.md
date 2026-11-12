# Third-party notices — GreenMusic Compose

GreenMusic is a Kotlin/Android application built with Jetpack Compose.

- QQ Music protocol/business logic is adapted from **Lilt**, https://github.com/Amamiya23/mygo-qyin at `c407d97c96fb13e75b4197994c6b145e44bf9dc3`, GNU AGPL-3.0. See [LICENSE](LICENSE), [reference source](vendor_reference/lilt) and [upstream notices](vendor_reference/lilt/THIRD_PARTY_NOTICES.md).
- UI, personalization and backup interaction designs are ported from the existing GreenMusic Flutter implementation, originally adapted from **Review** 3.14.0+238, https://github.com/Chengeeker/Review, MIT. See [license](docs/REVIEW_LICENSE) and [source inventory](docs/REVIEW_SOURCE.json).
- Glass optics are adapted from **liquid_glass_widgets** 1.13.0, copyright 2024–2026 Sebastian Degenaar, MIT, https://github.com/sdegenaar/liquid_glass_widgets. The original MIT license and its upstream renderer notices are included in `app/src/main/assets/licenses/LiquidGlass-MIT` and `LiquidGlass-notices`. The shader adaptation script is [glass_shaders.py](scripts/glass_shaders.py); its AGSL/GLES output is bundled with the application.
- The bottom navigation gesture, motion and rendering code is reused from RedNote Compose 1.1.0-compose.10. Its AGSL and GLES navigation shaders retain their original copyright notices and use the bundled liquid_glass_widgets license and renderer notices.
- **AndroidX / Jetpack Compose / Media3**, **Kotlin / kotlinx.coroutines**, **Material Components / Material Color Utilities / Material Icons**, **OkHttp / Okio**, **Coil**, and **Guava / Error Prone** retain their Apache-2.0 licenses. The full text is bundled in `app/src/main/assets/licenses/Apache-2.0`; dependency-provided notices remain in their artifacts. Runtime dependency versions are declared in [app/build.gradle.kts](app/build.gradle.kts).
- The existing player's visual hierarchy originally referenced **OuterTune** and **Retro Music Player** (GPL-3.0); their implementation, artwork and backends are not bundled. This native port follows GreenMusic's existing UI.

The application exposes the bundled full license texts under Settings → Open-source licenses. Build/test-only dependencies (Gradle, AGP, JUnit, Robolectric and MockWebServer) are not application runtime dependencies.

- Cylinder projection and slider value-indicator geometry are adapted from **Flutter**, copyright The Flutter Authors, BSD-3-Clause. The full license is bundled in `app/src/main/assets/licenses/Flutter-BSD`. Dynamic palette role mapping follows **dynamic_color** 1.9.0 (Material Foundation), Apache-2.0.

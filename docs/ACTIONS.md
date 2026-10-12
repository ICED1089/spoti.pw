# Actions for the stable-first development branch

To build your current feature candidate, use **[Build IPA — personal fork / optional Eevee](https://github.com/ICED1089/spoti.pw/actions/workflows/build-ipa.yml)**. Select branch `dev/v0.23`, supply a decrypted Spotify IPA URL, leave `include_beatit=true` for Core ML analysis and use `include_eevee=false` on the first test. The workflow checks that the latest stable code is an ancestor of dev before building.

To validate source, use **[Dev checks — DJ Mix / optional Sing](https://github.com/ICED1089/spoti.pw/actions/workflows/test-djmix.yml)**. This runs C/DSP tests and macOS iOS tweak compilation including BeatIt and Signalsmith. It is not a proof of live Spotify beatmatched transitions.

To inspect the feature inside the app, visit **Mod → Player → DJ Mix (experimental)**. It displays whether the audio tap is available and shows **Live beat-matched transitions: Not available** until an independent Song B decoded stream has been verified. The beat-analysis switch is off by default; restart after enabling it. Track analysis logs appear in Mod → Copy diagnostics after 35+ seconds of playback.

**Apple Music artist logos:** Mod → Appearance → Apple Music artist logos. The white-card renderings are now converted to transparent monochrome wordmarks when safe; unsupported or opaque artwork is rejected and the artist name is retained.

**Sing fix:** The player three-dot **Sing Mode → Off** must both turn the effect off and persist the setting, including after pause/resume. Please test this on the iPhone before promotion to stable.

**Compatibility:** Your diagnostics show Spotify **9.1.90** and report that its output audio import is unavailable. Use the version validated by the stable branch for your first DJ test; do not confuse BeatIt packaging with resolving a Spotify decoder/offset mismatch. The stable source decoder and pipeline implementations are retained exactly.

[Branch policy](BRANCH_POLICY.md) · [DJ engine implementation](DJ_MIX_IMPLEMENTATION.md)


## Build performance: warm vs. cold

The [October 12 Eevee+BeatIt run #38253786735](https://github.com/ICED1089/spoti.pw/actions/runs/38253786735) used **the archived old dev source** and ran about **19 minutes**. The logs show approximately **3m12s** extracting Spotify remote flags, **7m26s** for the complete spoti.pw build/injection, **1m54s** compiling renamed SwiftProtobuf, and **7m41s** compiling Eevee and its sideload shim. These are sequential and dominate wall time.

The **current** stable-based `dev/v0.23` IPA workflow now maintains three exact-match caches: (1) flags per exact decrypted Spotify IPA + extractor version; (2) compiled tweak/dependencies per source, IPA, DJ mode and Theos/Xcode revision; (3) Eevee package, shim and renamed SwiftProtobuf per pinned Eevee commit and toolchain. On a warm cache it skips those compiled stages and continues with IPA injection/verification. **About five minutes is a warm-cache goal, not a cold-build guarantee**; every source or IPA change that invalidates a cache may still take substantially longer. A rerun of an **old run ID** uses its old commit and cannot benefit from the current workflow modifications.

The default build **retains alternate app icon support** rather than silently dropping a feature to reduce build time. GitHub's runner provisioning, IPA download/injection and uploads still take unavoidable time.

Historical dev-only workflows and outdated changes are archived at [archive/dev-v023-pre-stable-rebase-20261012](https://github.com/ICED1089/spoti.pw/tree/archive/dev-v023-pre-stable-rebase-20261012). They are not active on the clean dev branch.

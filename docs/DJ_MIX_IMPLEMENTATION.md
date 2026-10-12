# DJ Mix open-source implementation — dev/v0.23

**Status:** the independent DSP/planning core, guarded two-deck PCM buffer and passive on-device analyzer are committed; pinned **BeatIt** Core ML inference is integrated and has compiled in GitHub Actions. **Spotify Song B independent audio and live Spotify song-to-song beat matching are not solved.** Never describe host-simulated transitions as working Spotify AutoMix.

## Open-source code actually reused

| Dependency | Upstream, license | How it is integrated |
| --- | --- | --- |
| **BeatIt / Beat This!** | [tillt/BeatIt](https://github.com/tillt/BeatIt) at `8d5f9ed80ddcdb8bbaea63d3dea26f137d366d01`; **MIT** | `vendor/beatit/Makefile` fetches only the pinned native Core ML/DBN source modules and model. `SGBeatItAnalyzer.mm`, adapted from our archived DJ branch, calls BeatIt's `analyze_with_coreml`. The vendor bundle contains its upstream license. |
| **Existing spoti.pw audio engine** | Open-source fork's `SGAudioPipeline`, `SGTimePitch`, `SGAudioRingBuffer`, archives | The lab registers a passive output observer without replacing Sing's source processor. Our existing time/pitch machinery is the candidate for rate matching; it is not currently driving a second Spotify deck. |
| **Switching-source algorithm reference** | [go-librespot player/source.go](https://github.com/devgianlu/go-librespot/blob/main/player/source.go), GPL-3.0 | Studied as a *design reference only*: it keeps a complete outgoing tail in reserve and requires a separately prefetched secondary audio source. No GPL code copied. |
| **Signalsmith Stretch + Linear** | [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) at `a670068d9aeb64913331d5cc29337b19a457a7df`; [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear) at `146b26f91b48835d665fa0498d64d9617818d27a`, both **MIT** | `vendor/signalsmith/Makefile` fetches both pinned header-only libraries. `SGDJStretch.mm` applies pitch-preserving 0.94..1.06x tempo changes **off the render thread** to independently supplied B PCM before `SGDJTwoDeckFeedB`. It does not find/download/decrypt Spotify B. Both license notices ship in the optional DJ resource bundle. |

The old archived DJ V2 pre-buffered both decks using **one sequential Spotify decoder queue**; it could not make the streaming subsystem produce Song B on demand and would fail when the native decoder had not delivered B's audio. That entire automatic path remains disabled.

## What is in dev now

- `Shared/DJMix/SGDJBeatPlan.{h,m}`: synthetic-envelope tempo detector as a fallback, beat/phrase-aware overlap planning and strict buffer, route and tempo checks.
- `Shared/DJMix/SGDJTwoDeck.{h,m}`: thread-aware fixed-size staging buffers for separately provided stereo PCM, equal-power crossfade, no memory allocation on the render callback and no partial deck consumption on underrun.
- `Shared/DJMix/SGDJStretch.{h,mm}`: actual MIT Signalsmith pitch-preserving incoming-deck preparation for slight BPM differences. Requires separately decoded B; the dual-deck mixer never invokes an FFT on the audio render thread.
- `Shared/DJMix/SGDJBeatProbe.{h,x}`: **off by default**, samples outgoing audio without modifying it; off-thread fallback rhythmic analysis. When the optional model is bundled, it captures one bounded 32-second mono window and calls the actual BeatIt native Core ML downbeat tracker off the render thread. It stores recent per-track grids and emits `dj lab` diagnostics.
- `Shared/DJMix/SGBeatItAnalyzer.{h,mm}`: actual open-source ML inference integration from our DJ archive. The model bundle can be located at the app root or Frameworks.
- `tests/djmix/beat_plan_test.c`: deterministic no-Song-B, tempo, buffer capacity, underrun, track-guard and chunk-continuity coverage.
- `.github/workflows/test-djmix.yml`: host tests with sanitizers, Sing output/dry-bypass regression tests, and real macOS iOS tweak build **with SG_DJ_BEATIT=1 and SG_DJ_STRETCH=1**, plus an independent sine-wave pitch-retention test for Signalsmith.

## Dev IPA — building and enabling

`Build IPA — personal fork / optional Eevee`, branch `dev/v0.23`:
1. Supply the user-owned decrypted Spotify IPA URL, starting with **9.1.88**.
2. **include_beatit=true** (default on the dev workflow) builds the pinned MIT/Core ML backend; the IPA job now verifies that the model resources are present. A default Theos source build without this option skips the model.
3. **include_eevee** remains independent. For first-run audio problem isolation, leave it off; enable after a clean baseline is known.
4. After installing, Mod Settings → Player → **DJ Mix laboratory** → **Analyze beat grids (experimental)**, then restart. The lab is **off by default** even in a BeatIt-enabled IPA.
5. Play a local song in the foreground for 35+ seconds, then Mod → Copy diagnostics. `dj lab: BeatIt Core ML tempo` confirms successful model inference; `dj lab: envelope tempo` indicates model unavailable/insufficient evidence. All logging avoids storing actual PCM in diagnostics.

The audio monitor uses transient PCM captured from playback, not a separate copy of Spotify's track. A pitch-preserving B stretcher is available, but it only processes B frames when a future independent source is provided. The model cannot infer the future track without future audio. When the future track has previously been analyzed, only its beat metadata is cached, **not** its decoded audio.

## Live AutoMix blocker and next architectural test

Live song-to-song beat matching requires both `A` and `B` as **independent, already playable PCM streams**, along with two timing clocks and pitch-preserving rate control. The planner explicitly fails when `independentStreams == false`; it does not pass false readiness through to the PCM mixer.

A candidate future input backend may come from a *legitimate* independent decoder capability or a supported Spotify-native transition engine, but the archived Spotify PCM queue and Chroma v0.51 string evidence do **not** prove one exists. Chroma references `automix.mode`, `automix.transition_uri`, `audio.speed_automation` and fading fields, suggesting native integration, but this does not disclose its gated implementation. We will not copy proprietary Plus code, spoof Plus entitlements or insert unverified private player hooks into normal playback.

Before enabling real live Spotify mixing: prove that both incoming and outgoing PCM are available before the handoff; prove clock continuity on Spotify 9.1.88, queue changes, pause, seek, Bluetooth and playback-speed changes; then wire the already-tested `SGDJTwoDeck` to the verified source. If B cannot be prepared, leave Spotify's native playback unchanged.

## Sing Off bug fix

In the redesigned player's three-dot menu, **Sing Off** now calls the shared Sing controller, persists `SGRKeySing=false`, and disables the configured engine. Previously the menu only turned off the controller's `wanted` flag while leaving the engine configured. The controller now also detaches immediately when off occurs while paused/interrupted, because no audio callback can finish a drain. Active playback retains original buffered samples and ramps back to the dry track to avoid an audible skip.

CI runs the existing native Sing timeline/stream tests (including dry-bypass, retained original and interruption cases) plus a regression check for the menu's persisted Off code path. A passing CI build is **not** proof that the iPhone's exact Spotify version and iOS behavior are correct.

## Promotion gate

The dev branch can be installed for the lab test, but `stable/v0.23` and the exact upstream baseline remain unchanged. Do not promote the AutoMix lab to stable until live playback and Sing Off are tested on-device. The independent two-deck test fixtures are not representative of Spotify transport buffering.

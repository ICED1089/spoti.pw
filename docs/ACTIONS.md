# GitHub Actions — personal v0.23 fork

This document is the short guide for **`ICED1089/spoti.pw`**, specifically the experimental **`dev/v0.23`** branch. The other repo (`ICED1089/EeveeSpotifyReincarnated`) has a separate **Build Chroma + Eevee** action that downloads an upstream release. **Do not use it to test changes in this repo.**

## Which workflow should I use?

| I want to... | Workflow file | GitHub Actions link | How to use |
| --- | --- | --- | --- |
| **Install the latest personal dev build** | `build-ipa.yml` | [Build IPA](https://github.com/ICED1089/spoti.pw/actions/workflows/build-ipa.yml) | Run workflow → select `dev/v0.23` → supply own decrypted Spotify 9.1.88 IPA URL; optionally tick Eevee |
| **Check DJ Mix code / iOS compilation** | `test-djmix.yml` | [Dev checks](https://github.com/ICED1089/spoti.pw/actions/workflows/test-djmix.yml) | Automatically runs for DJ code updates on dev; use workflow run history to inspect results |
| **Validate the published Sing model too** | `test-djmix.yml` | [Dev checks](https://github.com/ICED1089/spoti.pw/actions/workflows/test-djmix.yml) | Manually run with `verify_sing=true` |
| **Rebuild the Sing model (advanced)** | `rebuild-sing-model.yml` | [Maintenance](https://github.com/ICED1089/spoti.pw/actions/workflows/rebuild-sing-model.yml) | Manual maintenance only, not needed for routine IPA testing |

The **Release**, **CLA**, and **Publish Sing model** workflows on `main` are not regular dev-building workflows; they remain intact. GitHub may display the original workflow name from the default branch on the Build IPA action; the selected **branch** is what determines whether your run builds experimental dev code.

The old standalone menu, Sing download verification, and DJ iOS compile workflows have been archived under [`docs/workflow-archive`](https://github.com/ICED1089/spoti.pw/tree/dev/v0.23/docs/workflow-archive). Their actions were either redundant or consolidated. Historical Action runs cannot be erased just by deleting a workflow YAML file.

## Current DJ Mix implementation

- `tweak/Sources/Shared/DJMix/SGDJBeatPlan.m`: standalone onset/BPM detector, conservative phrase-aware planner, buffered two-PCM overlap gate and continuous equal-power offline mixer.
- `tweak/Sources/Shared/DJMix/SGDJTwoDeck.m`: bounded two-deck PCM ring and fail-closed mixing, exercised with synthetic independent tracks. It has no Spotify second decoder attached.
- `tweak/Sources/Shared/DJMix/SGDJBeatProbe.x`: **off-by-default** passive output observer that records an envelope, computes beat grids on a utility queue, and logs the result. This does not own the audio source or consume Spotify's next-track decoder.
- `tweak/Sources/Shared/Audio/SGAudioPipeline.h`: a separate passive monitoring slot after existing audio features.
- `tests/djmix/beat_plan_test.c`: synthetic tempo, guard-rail, clipping and chunk continuity tests.
- `test-djmix.yml`: Ubuntu unit tests/sanitizers, macOS iOS-tweak compilation against a build-only placeholder flag table, optional Sing model check.

**Current limitation:** No independent decoded Song B source has been proven. The planner explicitly sets `independentStreams=false` in the probe, so **no live overlap or beatmatched transition is attempted**. A passing compiler test does not imply live DJ mixing.

### To collect on-device DJ evidence

1. Run **Build IPA** on **`dev/v0.23`** with a decrypted Spotify **9.1.88** IPA (first pass: `include_eevee=false` to isolate errors).
2. Install the resulting artifact. In Mod Settings → Player → **DJ Mix laboratory**, enable **Analyze beat grids (experimental)** and restart Spotify.
3. Play music in the foreground for at least ~25–40 seconds on several different tracks, including a known 120–130 BPM track. Then copy **Mod → Copy diagnostics**.
4. Look for `dj lab: local tempo` and `dj lab: planned pair status` lines. **Status 1** means the independent second PCM stream is still unavailable, **not** a failed song.
5. Verify that Sing, seeking, playback speed, pause/resume, Bluetooth and crossfade settings still behave normally; disable the beat probe and restart if you see glitches.

## Rollback / safety

The source archives and `stable/v0.23` are untouched. Do not assume an action artifact has passed on-device tests. If the dev IPA fails or stutters, return to the known working stable IPA. Do not combine with the upstream Chroma release binary as a way to implement DJ Mix.

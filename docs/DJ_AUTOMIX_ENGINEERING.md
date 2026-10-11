# Independent AutoMix: engineering notebook

**Branch:** dev/v0.23. **Stable:** untouched. **Live beat-matched Spotify transitions:** not enabled.

## Source-backed reverse-engineering findings

Archived code: archive/main-with-dj-final, files tweak/Sources/Shared/DJ/SGDJAudio.m and SGDJ.m.

Our previous V2 attempted to prebuffer tracks A and B using ONE sequential Spotify decoder queue. Incoming B could only become available if that same decoder advanced far enough while A played from its retained buffer. If B never arrived in time, V2 could not arm or fell back to sequential playback. Increasing BPM accuracy cannot make absent decoded B audio playable. The old cheap tempo interpolation also produced crackling, so the experiment abandoned continuous tempo matching.

The supplied Chroma v0.51 binary contains strings SGAutoMixWatch, SGAutoMixCrossfade, automix.mode, automix.transition_uri, audio.crossfade_v2, fade start times and speed automation. These prove the identifiers exist but DO NOT prove Chroma's exact decoder, algorithm or authorization logic. We are not copying its Plus-gated implementation.

## Implemented in dev

| Component | Source | Status |
| --- | --- | --- |
| Onset/BPM estimator | Shared/DJMix/SGDJBeatPlan.m | Host-tested |
| Beat-aligned cue planner with explicit tempo ratio | Same file | Host-tested |
| Equal-power stereo two-PCM crossfade | Same file | Host-tested offline |
| Bounded, independent A/B ring buffers | Shared/DJMix/SGDJTwoDeck.m | Host-tested, strict prebuffer gate |
| Passive on-device beat monitor | Shared/DJMix/SGDJBeatProbe.x | Compiles on iOS; needs device playback test |
| Settings: DJ Mix laboratory | App/Pages.m | Off by default; restart required |
| Host CI and macOS Theos compilation | .github/workflows/test-djmix.yml | Passing |

The live monitor observes audio Spotify HAS ALREADY RENDERED, estimates BPM on a worker queue and stores small beat-grid summaries. It never owns the decoder or forces a new track to prebuffer, and does not disable Sing. The analysis result is a beat-phase hypothesis; a true downbeat/phrase boundary needs stronger musical analysis.

The planner deliberately receives independentStreams=false on-device. It therefore refuses every live overlap. The real-time decoder/second-deck problem remains unsolved rather than hidden by a misleading AutoMix toggle.

## Next engineering gates

1. Measure observed BPM on several known-tempo tracks (including uneven rhythms) and profile the cost.
2. Investigate legitimate independent decoded B PCM availability, including exact track identity, clock, buffering and cancellation; two AudioUnit routes or downloaded song bytes are NOT proof.
3. Verify B PCM is ready for the ENTIRE overlap plus cue and time-stretch reserve. Do not touch the real-time source to force it.
4. Connect pitch-preserving tempo processing through our SGTimePitch only after two stream sources exist; avoid the old crackling interpolator.
5. Prove handoff to Spotify's playback clock with no repeated or missing B samples, including seeks, skips, Connect and Bluetooth.
6. Improve real downbeat/phrase/key detection and run on-device listening/CPU tests.
7. Only then allow an opt-in audible transition mode. Leave stable untouched until tested.

## How to run this experiment

Use GitHub Actions, Build IPA from your own Spotify IPA, select dev/v0.23, and supply a decrypted Spotify 9.1.88 IPA URL. Begin with Eevee disabled to isolate DJ audio behavior.

Install, then Mod Settings > Player > DJ Mix laboratory > Analyze beat grids (experimental), restart Spotify and play 30–40 seconds per test track. Use Mod > Copy diagnostics and search for 'dj lab: local tempo' and 'dj lab: planned pair status'. Status 1 means independent Song B PCM is unavailable; it is EXPECTED currently. Verify seeking, Sing, playback speed, pause/resume and output routes; disable and restart if there is an issue. Keep the working stable IPA for rollback.

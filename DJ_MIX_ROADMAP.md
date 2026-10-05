# DJ Mix Roadmap — v0.23 Personal Fork

> Research/planning document only. No DJ Mix implementation has been started.
>
> Research snapshot: 2026-10-06
>
> Target branch/build family: `stable/v0.23` + Eevee 7, with spoti.pw owning UI/audio/features.

## Goal

Build a local DJ-mixing system inside the personal Spotify fork without depending on Spotify enabling its server-side Mix/DJ features.

The long-term target is not a simple crossfade. The target is:

1. **V1 — Smart DJ Mix:** locally analyzed, beat/phrase-aware transitions using one Spotify playback stream.
2. **V2 — Two-Deck DJ Mix:** genuine overlapping, beat-matched two-track transitions if Spotify's audio pipeline can safely expose/prebuffer both sides.
3. **V3 — AI DJ:** a learned transition planner that chooses cue points, techniques, ordering, and optionally stems/voice based on the music.

This feature belongs to **spoti.pw**, not Eevee. Eevee remains responsible for Premium/account patches, ad blocking, and privacy.

---

# What Spotify's own Mix feature tells us

Spotify's public Mix feature is a useful quality target.

Spotify says its Mix system exposes:

- BPM
- song key
- waveform data
- beat data
- automatic transitions
- volume curves
- EQ curves
- effects
- Smart Reorder using BPM and key

This strongly suggests that good automatic mixing is not just "fade for N seconds." The transition planner needs musical analysis and a deliberate transition point.

Official references:

- Spotify Mix announcement:
  https://newsroom.spotify.com/2025-08-19/mix-your-favorite-playlists-seamlessly-by-adding-your-own-transitions/
- Spotify Mixed Playlists support:
  https://support.spotify.com/article/mixed-playlists/
- Spotify Smart Reorder:
  https://newsroom.spotify.com/2026-02-25/smart-reorder-playlist-mixing/

We do **not** need Spotify's private BPM/key/beat database if we can analyze decoded audio locally.

---

# What v0.23 already gives us

The current fork already has more of the required foundation than expected.

## 1. A real decoded-audio pipeline

Relevant files:

- `tweak/Sources/Shared/Audio/SGAudioPipeline.h`
- `tweak/Sources/Shared/Audio/SGAudioPipeline.x`

The pipeline sits between Spotify's mixer/decoder path and the output.

It already supports ordered processors for:

- Sing
- speed/pitch
- audio effects
- haptics

This is the correct layer for DJ DSP.

## 2. Time-stretch and pitch-shift

Relevant files:

- `tweak/Sources/Shared/Player/SpeedPitch.x`
- `tweak/Sources/Shared/Player/SGTimePitch.m`

The fork can already:

- change playback speed
- preserve pitch while changing speed
- optionally make pitch follow speed
- shift pitch by semitones
- keep Spotify's visible playback clock aligned with altered playback speed

This means BPM matching does not require inventing a time-stretch engine from scratch.

## 3. Player state and future queue metadata

Relevant files:

- `tweak/Sources/Headers/SPTPlayer.h`
- `tweak/Sources/Shared/Player/PlayerState.x`

`SPTPlayerState` exposes:

- current track
- duration/position
- `future` tracks
- previously played/reverse tracks
- playback state
- context/shuffle/repeat state

This gives the planner the identity of upcoming tracks even when their audio is not yet independently available.

## 4. Existing next-track boundary/read-ahead work

Relevant files:

- `tweak/Sources/Shared/Audio/SGAudioSourceQueue.m`
- `tweak/Sources/Shared/Sing/SGSingAudio.m`
- `tweak/Sources/Shared/Sing/SGSingController.m`

Sing already:

- detects a verified natural song boundary in Spotify's decoder queue
- can preserve audio/stem processing across a natural track change
- knows the expected next track from `state.future.firstObject`
- can carry a single inference stream across the boundary

This is highly relevant to V2.

### Critical limitation

`SGAudioSourceQueueInitialize()` is currently verified against the **Spotify 9.1.78 arm64 binary UUID and exact private code signatures/offsets**.

Our current daily build is Spotify **9.1.88**.

Therefore:

> Do not assume next-track read-ahead works on 9.1.88.

Before V2 work, the source-queue layout must be rediscovered/reverified for the current Spotify binary and wrapped in a compatibility adapter rather than hardcoded forever.

This is a hard V2 gate.

---

# Audio-analysis research

## Beat / downbeat / BPM

### Strong research candidate: Beat This!

Beat This! is an ISMIR 2024 beat/downbeat tracker.

- Repo: https://github.com/CPJKU/beat_this
- License: MIT
- Paper/repo describes modern accurate beat tracking without DBN post-processing.

There is also a native Apple-oriented project called **BeatIt** that wraps Beat This!/other trackers behind Core ML and native C++/Objective-C++ infrastructure:

- https://github.com/tillt/BeatIt
- MIT
- CoreML backend
- native C++/Objective-C++ pipeline
- Accelerate-based DSP
- sparse analysis windows instead of necessarily processing the entire song densely

This architecture is especially interesting for our iOS fork.

### Conservative DSP candidate: Essentia

Essentia provides mature C++ MIR algorithms including:

- BPM
- beat positions
- tonal/key analysis
- loudness
- spectral descriptors
- danceability

References:

- RhythmExtractor2013:
  https://essentia.upf.edu/reference/std_RhythmExtractor2013.html
- KeyExtractor:
  https://essentia.upf.edu/reference/streaming_KeyExtractor.html
- MusicExtractor:
  https://essentia.upf.edu/tutorial_extractors_musicextractor.html

Essentia can be cross-compiled as a lightweight iOS library using Accelerate for FFT.

Important licensing note: Essentia itself is AGPL-3.0-or-later unless separately licensed. Do not casually copy it into this project without reviewing compatibility/obligations. For a personal experiment it remains technically useful as a reference/benchmark, but **Beat This!/BeatIt's MIT path is cleaner for code reuse**.

## Musical key

A DJ-friendly key system can be built from estimated musical key/scale and mapped to Camelot notation.

Initial plan:

- detect key + major/minor
- store confidence
- map to Camelot
- prefer compatible transitions:
  - same Camelot cell
  - +/-1 around the wheel
  - relative major/minor
- do not force key matching when detector confidence is poor

## Phrase / cue-point detection

A good mix needs phrase-level timing, not only BPM.

Useful research:

**Automatic Detection of Cue Points for DJ Mixing**
https://arxiv.org/abs/2007.08411

The paper reports a rule/novelty-analysis method for switch points and found about 96% of generated points suitable for DJ mixing in its evaluated EDM setting.

**DJ StructFreak**
https://ismir2023program.ismir.net/lbd_328.html

This work explicitly treats music structure and mix-point selection as central to automatic DJ quality.

Likely useful local features:

- beat/downbeat grid
- novelty curve
- loudness/energy
- spectral flux
- low-frequency/bass energy
- vocal activity
- section boundaries
- intro/outro confidence
- phrase lengths such as 4/8/16/32 bars

---

# V1 — Smart DJ Mix

## Product goal

Create transitions that feel intentionally DJ'd while still using Spotify's normal single active playback stream.

Target experience:

> turn on DJ Mix -> play a queue/playlist normally -> transitions happen automatically at musically sensible positions

V1 should be useful even if true two-track simultaneous decoding is not yet available.

## V1 scope

### Local Track Analysis

For every track we are able to analyze, cache:

- Spotify track URI
- duration
- BPM
- BPM confidence
- beat timestamps
- downbeat/bar phase
- key
- key confidence
- Camelot key
- loudness/energy curve
- likely structural/cue points
- intro/outro candidates
- analysis version

The cache must be versioned so better analysis algorithms can invalidate/rebuild old entries.

### Cache-first reality

We do not currently have proven arbitrary access to the entire *next* track's PCM before it becomes active.

Therefore V1 must support two cases:

1. **Analyzed next track:** full smart transition planning.
2. **Unknown next track:** safe fallback transition; analyze/cache it while it plays for future use.

Do not silently pretend first-play tracks have full analysis.

### Transition planner

Given Track A and Track B analysis:

1. choose an outgoing phrase boundary
2. choose an incoming cue point
3. compare BPM
4. compare key
5. compare energy
6. select transition length
7. choose a transition recipe
8. execute it through the existing audio pipeline

### First transition recipes

Keep V1 deterministic and testable.

**Smooth**
- 16 or 32 beats
- modest tempo convergence
- equal-power volume fade
- bass/low EQ handoff near a downbeat

**Quick**
- 4 or 8 beats
- minimal tempo adjustment
- useful when tracks are poorly matched

**Rise**
- outgoing low/mid reduction
- incoming gain rise
- optional reverb/echo tail

**Clean Cut**
- phrase-aligned cut on a downbeat
- used when overlap would sound worse than a cut

### BPM matching rules

Do not force extreme time stretching.

Initial guard rails:

- normalize half/double-time interpretations
- prefer small BPM differences
- cap tempo adjustment to a conservative range initially
- if required stretch exceeds the quality limit, choose a shorter/cut transition instead
- restore user playback speed/pitch state after transition

Use the existing `SGTimePitch` path rather than building another time-stretcher.

### Key matching rules

Key compatibility influences the recipe but is not an absolute requirement.

If two tracks clash harmonically:

- choose a shorter transition
- move the bass handoff earlier
- avoid long simultaneous tonal sections
- optionally pitch-shift only within a small quality-safe range

### V1 UI

Keep the initial UI small:

**DJ Mix**
- Off / On

**Style**
- Auto
- Smooth
- Club
- Quick

**Intensity**
- Low / Normal / High

Optional debug/details page:

- A BPM/key
- B BPM/key
- selected cue points
- transition length
- selected recipe
- confidence/reason
- fallback reason

### V1 diagnostics

Every transition should log:

- track A/B URI hashes or privacy-safe identifiers
- detected BPM/key/confidence
- selected cue points
- tempo ratio
- recipe
- execution timing error
- underruns
- fallback reason

This should flow into the existing Mod -> Diagnostics export.

## V1 success criteria

- no crashes or audio graph corruption
- normal Spotify playback remains unchanged when DJ Mix is off
- no audible gap on supported transitions
- beat-aligned transition timing within a small perceptual tolerance
- speed/pitch restores correctly
- bad-match tracks fall back gracefully
- no sustained battery/CPU work when DJ Mix is off
- analysis is cached and not repeated unnecessarily

## V1 expected quality

For stable-tempo pop/electronic/house/techno with already analyzed tracks, the goal is a genuinely good automatic mix, not merely crossfade.

For live drums, unusual meters, tempo changes, weak intros/outros, or low-confidence analysis, V1 should choose conservative transitions instead of forcing a bad "DJ" effect.

---

# V2 — Two-Deck DJ Mix

## Product goal

Play the outgoing and incoming Spotify tracks simultaneously for a real DJ-style overlap.

Target:

```
Track A  =====================\\____
                         16/32-bar blend
Track B              ____/====================
```

This unlocks:

- actual beatmatched overlap
- longer blends
- independent EQ curves for A and B
- bass swaps
- better phrase matching
- echo/reverb outs while B is already playing
- more human-DJ-like transitions

## V2 hard feasibility question

Can the fork safely obtain **two independently controllable decoded audio streams** from Spotify?

Current code proves only that:

- we can process the active decoded stream
- we can inspect a verified source queue
- Sing can see/carry a small continuous prefix across a natural track boundary on a verified Spotify build

It does **not** yet prove:

- independent Deck A PCM
- independent Deck B PCM
- arbitrary pre-seek of B
- independent clocks
- enough prebuffer to perform a long 16/32-bar overlap

Do not start V2 DSP until this is proven.

## V2 research/prototype gates

### Gate A — Spotify 9.1.88 source-queue compatibility

Reverify the decoder callback/layout for 9.1.88.

Preferred design:

- version-specific adapter
- binary/signature verification
- fail closed when layout is unknown
- never guess offsets
- diagnostics show supported/unsupported

### Gate B — second-track audio availability

Investigate whether Spotify already:

- decodes B before A finishes
- keeps a second decoder/player internally
- exposes an independently pullable prebuffer
- can be asked through an existing internal player path to prepare B without interrupting A

Prototype must be read-only/diagnostic first.

### Gate C — dual-stream clocks

If two sources exist, establish:

- source A position
- source B position
- sample-accurate common output clock
- seek/skip/route-change invalidation
- buffer ownership
- deterministic handoff to Spotify after the blend

### Gate D — two-deck mixer

Only after A-C pass:

- independent gain A/B
- independent low/mid/high EQ curves
- independent time-stretch where necessary
- common beat phase
- limiter/headroom protection
- fail-safe bypass back to Spotify

## V2 quality strategy

A strong DJ transition should use:

- phrase alignment first
- tempo match second
- harmonic compatibility
- bass management
- energy trajectory
- limited effects

Avoid effects that hide bad timing instead of solving it.

## V2 success criteria

- two real streams overlap without glitches
- no duplicate/phantom playback after transition
- no queue corruption
- seeking/skipping during transition safely aborts
- route changes safely abort
- lock screen/player clock stays believable
- transition timing stays sample/beat aligned
- CPU/thermal state remains acceptable
- unsupported Spotify versions fall back to V1, not a crash

---

# V3 — AI DJ

## Product goal

Make the system choose *how* to DJ instead of following fixed transition rules.

V3 is not "put an LLM in the audio callback."

The real-time audio path stays deterministic DSP.

AI should operate **above** the audio renderer:

```
music analysis
    ↓
transition candidates
    ↓
AI / learned planner
    ↓
transition recipe + parameters
    ↓
deterministic DSP engine
```

## V3 Layer 1 — richer analysis

Add:

- phrase/section embeddings
- vocal activity
- drop/break/build detection
- timbre similarity
- rhythmic density
- energy trajectory
- genre/style cues
- transition risk score

## V3 Layer 2 — learned transition planner

Research reference:

**DJtransGAN — Automatic DJ Transitions with Differentiable Audio Effects and GANs**
https://github.com/ChenPaulYu/DJtransGAN
https://arxiv.org/abs/2110.06525

Its pipeline is directly relevant:

1. beat/downbeat tracking
2. key estimation
3. structure boundary detection
4. mixability estimation
5. BPM/key/cue-region alignment
6. learned EQ/fader transition parameters

The published work used a differentiable EQ/fader generator and achieved competitive listening-test results against baselines.

We should treat it as research inspiration, not blindly drop the Python/PyTorch project into an iPhone tweak.

A practical V3 model could predict:

- transition type
- outgoing cue
- incoming cue
- transition bar length
- tempo target
- low/mid/high EQ curves
- crossfade curve
- effect amount
- confidence

Then our native DSP executes those parameters.

## V3 Layer 3 — learned ordering / Smart Reorder

For queues/playlists where reordering is allowed, score candidate next tracks using:

- BPM distance
- Camelot/key compatibility
- energy trajectory
- timbre/genre similarity
- vocal collision risk
- desired user direction: build / maintain / cool down

Do not reorder normal albums/queues unexpectedly. This should be an explicit DJ Mix option.

## V3 Layer 4 — optional stem-aware transitions

Stem separation could enable:

- vocal-out -> instrumental-in
- bass swap without muddy overlap
- drum-only bridge
- instrumental underlay
- cleaner long transitions

Research candidate:

**Demucs / HTDemucs**
https://github.com/adefossez/demucs

There are community projects demonstrating Core ML/iPhone HTDemucs conversion and mobile separation, so on-device stems are technically possible.

However this is expensive:

- large model
- memory
- battery
- thermal cost
- latency
- storage/cache size

Therefore stems are **optional V3**, not a V1/V2 dependency.

Prefer:

- background/precompute
- cache results
- only for tracks likely to be mixed
- thermal/memory guards
- graceful no-stem fallback

## V3 Layer 5 — optional AI host

Separate from mixing.

Possible future feature:

- short DJ-style spoken links
- generated locally or through a chosen model/service
- volume-duck music underneath
- aware of artist/title/mood

This should never be required for AI DJ mixing and should stay off by default.

---

# Recommended technical stack

## V1

Preferred starting stack:

- existing v0.23 `SGAudioPipeline`
- existing `SGTimePitch`
- existing `SPTPlayerState`/queue metadata
- native DSP for EQ/fades
- Beat This!/BeatIt-style CoreML path for beat/downbeat if it proves portable to iOS
- own lightweight tonal/energy/structure code or another license-compatible implementation
- SQLite/plist/binary analysis cache keyed by Spotify URI + analysis version

Avoid putting Python or PyTorch runtime inside the tweak.

## V2

Add only after feasibility gates:

- Spotify-version-specific source adapter
- dual decoded-stream abstraction
- sample-accurate two-deck mixer
- per-deck EQ/gain/time stretch
- transition scheduler

## V3

Add:

- Core ML transition scorer/planner
- optional structure embedding model
- optional Demucs-style stems
- cached ML outputs
- deterministic native renderer

---

# Performance principles

1. DJ Mix Off = essentially zero extra ongoing work.
2. Never analyze on the audio render thread.
3. Cache expensive analysis.
4. Use background/low-priority work.
5. Pause heavy analysis on thermal pressure.
6. Pause or degrade on low memory.
7. Do not load large ML models at Spotify startup.
8. Load models lazily when DJ Mix is enabled/needed.
9. Keep real-time render callbacks bounded and allocation-free.
10. Fail back to normal Spotify playback on any uncertainty.

---

# Safety / rollback principles

DJ Mix touches the most fragile part of the tweak: live audio.

Every stage must have:

- one global kill switch
- instant bypass to original Spotify audio
- route-change invalidation
- seek/skip invalidation
- Spotify-version support check
- diagnostics
- no permanent queue mutation unless explicitly requested

Never let an unsupported Spotify version guess private audio offsets.

---

# Development order

## Research Stage — no user-facing feature

1. benchmark beat/BPM candidates on Mac using test audio
2. compare Beat This!/BeatIt vs a simple DSP baseline
3. prototype key/Camelot detection
4. prototype phrase/cue detection
5. define analysis-cache format
6. investigate/reverify Spotify 9.1.88 source queue
7. determine whether independent next-track PCM is possible

## V1

1. analysis engine
2. cache
3. transition planner
4. single-stream transition scheduler
5. EQ/fade DSP
6. UI
7. diagnostics
8. real-phone listening tests
9. tune rules by genre/confidence

## V2

Only if dual-stream feasibility passes:

1. deck abstraction
2. Deck B prebuffer
3. common clock
4. overlap mixer
5. independent EQ/time stretch
6. phrase-locked transitions
7. interruption/route/skip recovery
8. stress + thermal tests

## V3

Only after V2 is stable enough:

1. collect/prepare transition examples
2. offline feature/label pipeline
3. transition-scoring model
4. Core ML conversion
5. on-device inference
6. compare learned planner against V1/V2 rules
7. optional stem-aware mixing
8. optional AI host

---

# Quality benchmark

We should not claim "Spotify quality" based on architecture alone.

Test using blinded A/B listening:

- normal Spotify crossfade
- our V1
- our V2
- Spotify Mix when available
- hand-tuned reference transitions

Rate:

- beat alignment
- phrase correctness
- harmonic clash
- bass muddiness
- loudness jump
- artifacts from time stretch
- transition naturalness
- whether listener notices the transition for the wrong reason

The goal is to improve measured/listened quality, not to maximize the number of effects.

---

# Current feasibility verdict

## V1

**Feasible.**

Most core playback/DSP infrastructure already exists. The main work is analysis, planning, caching, transition scheduling and native EQ/fade control.

## V2

**Plausible, not yet proven.**

The existing Sing/read-ahead code is encouraging, but true independent Deck B audio has not been established, and the source-queue verifier is currently tied to Spotify 9.1.78.

## V3

**Feasible as a future planner if V1/V2 provide a reliable renderer.**

AI should decide transition parameters; it should not replace the real-time DSP engine. Stem-aware AI is possible but should remain optional because of model size, compute, memory and thermal cost.

---

# Research references

Spotify:
- https://newsroom.spotify.com/2025-08-19/mix-your-favorite-playlists-seamlessly-by-adding-your-own-transitions/
- https://support.spotify.com/article/mixed-playlists/
- https://newsroom.spotify.com/2026-02-25/smart-reorder-playlist-mixing/

Beat / tempo:
- https://github.com/CPJKU/beat_this
- https://github.com/tillt/BeatIt
- https://github.com/mjhydri/BeatNet
- https://essentia.upf.edu/reference/std_RhythmExtractor2013.html

Key / MIR:
- https://essentia.upf.edu/reference/streaming_KeyExtractor.html
- https://essentia.upf.edu/tutorial_extractors_musicextractor.html

Cue/structure:
- https://arxiv.org/abs/2007.08411
- https://ismir2023program.ismir.net/lbd_328.html

Automatic DJ research:
- https://arxiv.org/abs/2110.06525
- https://github.com/ChenPaulYu/DJtransGAN
- https://github.com/ChenPaulYu/DJtransGAN-dg-pipeline
- https://arxiv.org/abs/2008.10267

Stem separation:
- https://github.com/adefossez/demucs

---

# Decision when this project is resumed

Before writing DJ Mix production code:

1. re-read this document
2. inspect current Spotify version and audio pipeline
3. verify the user still wants DJ Mix work
4. get explicit approval before modifying code
5. start with the Research Stage, not V2/V3 shortcuts

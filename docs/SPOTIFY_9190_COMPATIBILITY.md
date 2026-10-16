# Spotify 9.1.90 compatibility — investigation, not a support claim

**Branch:** `dev/v0.23` only. Do not modify `stable/v0.23` or `baseline/v0.23-beta`.
**Status (2026-10-16):** Spotify 9.1.90 is current on the App Store and Taurus v0.60 advertises support, but **our complete v0.23 feature set has not been verified** on this IPA.

## Current evidence

- Our IPA builder accepts a decrypted Spotify IPA of any version. Its successful completion proves packaging, **not** that Spotify hooks or playback function.
- The project's existing 9.1.90 diagnostics report that **runtime rebinding** of `AudioOutputUnitStart` failed, so the audio pipeline reports unavailable and Sing, speed/pitch, effects and DJ analysis may be impaired. A static inspection of the user-owned October 13 development IPA establishes that this is **not evidence of a missing Spotify import**: the 9.1.90 executable contains `_AudioOutputUnitStart`, `_AudioUnitSetProperty`, and `_AudioComponentInstanceDispose` in its classic undefined-symbol table and indirect pointer slots within `__DATA_CONST,__got`. The Mach-O also has `LC_DYLD_CHAINED_FIXUPS`. The failure needs runtime log diagnosis (guest image selection, slot patching, loaded layout or environment); no rebind behavior was changed. See `Shared/Audio/SGAudioPipeline.x`, `Core/SGRebind.m`, and `docs/ACTIONS.md`.
- Static binary reference: Spotify **9.1.90 (919002269)**, executable UUID **`fbce22c1-7e1b-3e0d-9be8-66ff9291943e`**. Undefined symbol indices `125`, `130`, `112`, respectively; classic indirect pointer addresses `0x10cbf1d70`, `0x10cbf1d98`, `0x10cbf1d08`. These are **analysis references, not safe live offsets or signatures**; never use them as unverified hook targets.
- `SGAudioSourceQueue.m` has verified UUID/layout pairs for **9.1.78** and **9.1.88**, not 9.1.90. Do not reuse those code offsets simply because a private callback looks similar; only a matching Spotify executable UUID plus instruction signatures can authorize source queue access.
- The independent DJ Mix tests are not evidence of working Spotify audio on 9.1.90.
- Taurus `samj-exe/taurus` README targets Spotify 9.1.90 and directs source reviewers to GitLab. We were unable to read its current GitLab source. A README/release target alone is not proof of hook-by-hook parity, and copying post-v0.23 proprietary implementation is not authorized.

## Read-only runtime diagnostics added on dev

`Mod → Copy diagnostics` now includes a **Spotify runtime compatibility probes** section:

1. UUID of the loaded executable matching Spotify's `CFBundleExecutable`; if none or ambiguous, the report explicitly says so.
2. Presence of the player/Now Playing and animated-video classes and selectors we depend on.
3. Existing audio pipeline status, rebinding log, and source commit.

A present selector is only evidence of a runtime name; it does **not** prove method semantics or safety. Probes do not patch, invoke, or read private Spotify data. Review diagnostics before sharing: the separate screen tree may contain text from the UI.

## How to validate one Spotify 9.1.90 IPA

1. Build `dev/v0.23` using the user-owned decrypted **9.1.90** IPA and record its executable UUID. First set `include_eevee=false`, `include_beatit=false` for isolation.
2. On the iPhone check: app launches, Home/Search/Library, tab navigation, player open/close, track skip, queue, lyrics, artwork, background/foreground, lock screen, Live Activity.
3. Play normally, then export diagnostics. Check `Audio pipeline`, `rebind:`, `audio source queue:`, and the new class/selector probes.
4. On the verified 9.1.90 IPA the AudioUnit imports and classic GOT pointers **are present**. Inspect the on-device rolling log for `rebind:` lines to determine why `SGRebindImport` still reports failure. Distinguish wrong guest executable, missing loaded import, failed `vm_protect`, and unavailable replacement slots; do not assume Spotify removed an audio API. Do not patch by guessed offsets or enable broken processors. Any new audio binding requires evidence and a rollback path.
5. Only after solo playback succeeds, repeat with Eevee 7 enabled. Avoid concurrent control of UI and lyrics by both mods; check Live Activity survives injection.
6. Compare the same test matrix against the known-good version and retain the exact IPA version, UUID, iOS version, build commit and Eevee revision.

## Promotion gate

Do not call 9.1.90 supported or promote the feature to `stable/v0.23` until the failing audio import is understood and the iPhone tests pass. Absence of a crash, a passing Theos compile, or Taurus advertising 9.1.90 are not sufficient.

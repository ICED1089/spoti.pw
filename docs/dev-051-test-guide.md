# v0.51-inspired dev integration: build and device test guide

**Branch:** `dev/v0.23` (no stable/main modifications)
**Baseline:** Spotify 9.1.88 for daily use, with verified queue signatures for 9.1.78 and 9.1.88.
**Status:** Source changes committed. iOS compilation, Apple Music catalog responses and on-device playback have **not** been verified in this session.

## Scope and what is not implemented

This test build contains independently written code, not Chroma's patched binary.

| Component | Implemented in dev | Device test expectation |
| --- | --- | --- |
| Apple Music artist wordmarks | Artist catalog editorial-artwork lookup, resized PNG URL, opt-in redesigned header and accessible fallback | Logo when editorial wordmark is returned and downloaded, otherwise original text |
| Apple Music animated covers | Existing v0.23 player, album and lock-screen animations retained; opt-in constrained-network downloads, better cancellation/retry behavior and bounded lookup caches | Same motion artwork with fewer wasted retries; no new v0.51 rendering engine |
| Lyrics / performance | 40-entry LRU instead of whole-cache clearing; Apple cover/logo metadata LRU; Live Activity non-lyric pages now poll at 1 Hz (timed lyrics retain 4 Hz) | Fewer repeated lyrics/catalog lookups and background wakeups |
| Spotify decoder compatibility | Existing verified 9.1.78 + 9.1.88 layouts from stable | Graceful fail-closed for any other binary UUID |
| Native crossfade compatibility | Optional synchronization of Spotify's user-chosen crossfade duration and switch using its existing preferences implementation | Standard crossfade only when supported by Spotify's own player/account/context |
| Beat-matched Chroma-style AutoMix | **Not implemented** | No independent Song B decoder or proprietary Plus implementation; do not claim beat matching |

## Build the actual branch

1. On GitHub open **Actions → Build IPA from your own Spotify IPA**.
2. Choose the **`dev/v0.23`** branch in the Run workflow selector.
3. Paste a direct link to your own decrypted Spotify IPA into `ipa_url`; use **9.1.88** for the first test.
4. Choose **artifacts** for `upload_method`; run the workflow.
5. Download the resulting `spoti.ipa` artifact, install with your ordinary personal build workflow, and keep the previous working IPA as a rollback.
6. Inspect the run logs. Compilation or patch errors require fixing before any device test; a GitHub commit alone is not proof of a working IPA.

## Device test sequence

### Artist logos

Under Mod Settings → Appearance (Redesigned UI), enable **Apple Music artist logos**, then restart Spotify. Test a well-known artist with an official transparent Apple Music wordmark, a smaller artist and an artist with an ambiguous name. Verify the title remains legible and selectable via accessibility. Turn the option off and restart to recover the original labels. The Apple Music editorial response shape and available artists are not established without live testing.

### Animated artwork

Use the existing redesigned player animated background and animated lock screen. In a foreground playback session:
- Open an album with known Apple Music motion art and confirm the album hero plays.
- Play its song in the full-screen player and check the first frame appears without a black flash.
- Quickly skip through 5–10 tracks and return to a recently visited track; stale clips must not display.
- Lock and unlock on iOS 26+ to test `MPMediaItemAnimatedArtwork`.
- Repeat with Low Power Mode and Reduce Motion enabled (fallback to still artwork).
- Optionally enable **Download animated covers in Low Data Mode** on the Lock screen widget page; it is **off by default** and permits constrained downloads.

### Performance

Play at least 45 distinct tracks and return to songs already played. The lyrics cache should evict least recently used tracks, not everything at its 40-entry limit. Revisit Apple artwork to exercise the bounded 128-cover lookup and 80-artist-logo lookup caches. Compare Home scrolling and CPU/battery with stable under the same conditions. Switch Live Activity among lyrics, queue and controls: lyric transitions should retain their old cadence; non-lyric pages can update at 1-second intervals.

### Native transitions

Open Mod Settings → Player → **Transitions (experimental)**. Turn on **Synchronize native crossfade**. In Spotify's own supported Playback Settings, change its crossfade duration. The hook only keeps the associated switch in sync with Spotify's own action. Test transitions between playlist tracks on local playback, then on album playback, a queue and Spotify Connect.

**Important:** This is not a beat-matched AutoMix implementation. Spotify can ignore crossfade for restricted playback contexts, and we do not force subscription entitlements or import Chroma Plus components. If playback glitches, switch this option off and restart; the experiment does not own Spotify's DSP.

### Audio regression checks

Play normally for 30 minutes; try skipping, Previous, relative seeks, higher playback speed, pause/resume, Sing on/off, Bluetooth output changes, offline playback and Spotify Connect. Watch for track silence, rebuffering and audio crashes. The previous DJ V2 source/deck mixer is deliberately absent.

## Research evidence

The uploaded v0.51 package and kit contain identical `spotifyglass.dylib` bytes. Strings support native transition integration: `SGAutoMixWatch`, `SGAutoMixCrossfade`, `automix.mode`, `automix.transition_uri`, `automix.auto_preset_id`, `audio.fade_overlap`, `audio.fade_in_start_time`, `audio.fade_out_start_time`, `audio.speed_automation`, and `audio.crossfade_v2`. These do **not** establish exact control flow, independent decoding, audio quality or legitimate feature availability.

Apple visual leads include `editorialArtwork`, `musicContentColorLogoTrimmed`, `editorialVideo`, `motionTallVideo3x4`, `motionSquareVideo1x1` and Low Data Mode messaging. v0.23 already used the Apple Music editorial video and HLS path; it was enhanced rather than replaced.

Native REA-style decompilation was not performed because there was no configured Ghidra/Hopper/IDA engine. These are source and static Mach-O/string findings, **not runtime-verified algorithm recovery**.

## Rollback and promotion

Do not promote to `stable/v0.23` until the GitHub Actions build succeeds and device tests pass. The reference branches `baseline/v0.23-beta`, `main` and DJ archives are unchanged. Disable artist logos and crossfade sync independently if they misbehave; for a complete rollback install your known working stable IPA.

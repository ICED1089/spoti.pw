# Development build — Apple Music artist logos

Our `dev/v0.23` branch keeps `stable/v0.23` as its base. The experimental DJ Mix analyzer, two-deck code, BeatIt model, Signalsmith dependencies, dedicated test workflow, and build options were removed from **dev**. The old experiments remain in Git history; stable and baseline were not changed.

## Build

Run [Build IPA — personal fork / optional Eevee](https://github.com/ICED1089/spoti.pw/actions/workflows/build-ipa.yml) on branch `dev/v0.23`. Provide a direct URL for your own decrypted Spotify IPA. Leave `include_eevee=false` for the first check, then test Eevee 7 separately.

[Dev checks — artist logos and stable audio](https://github.com/ICED1089/spoti.pw/actions/workflows/test-dev.yml) compile the tweak and verify stable ancestry, unmodified stable audio implementations, preserved logo UI, and the absence of DJ components. They cannot establish iPhone compatibility by themselves.

## Apple Music artist logos

Enable **Redesigned UI**, then **Mod → Appearance → Apple Music artist logos**, and restart. Only exact Apple Music editorial wordmarks are used. Apple's artist-logo feature launched with iOS 27 and artist/label submissions are optional, so many artists will correctly show their text names instead.

The code retries transient lookup failures with a cooldown and expires negative catalog results after ten minutes. If a logo you expect is absent, use **Mod → Copy diagnostics** and check `redesign artist:` logs for a catalog miss, token/HTTP error, image-download error, or successful load. Review the visible screen text before sharing diagnostics.

## Stability and compatibility

The Sing Off menu fix and other small unpromoted stability work remain in dev; they have not been promoted to stable. Spotify **9.1.90** still needs on-device feature testing; an older diagnostic identified a runtime audio rebinding failure although the inspected binary contained the audio symbols. See [Spotify 9.1.90 investigation](SPOTIFY_9190_COMPATIBILITY.md). A successful IPA build is not proof of playback compatibility.

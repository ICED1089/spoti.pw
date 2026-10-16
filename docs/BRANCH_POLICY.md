# Branch policy — stable first

**The source of truth is `stable/v0.23`.** The experimental branch `dev/v0.23` must always contain the exact latest stable history and add only unpromoted future features.

## Required sequence

1. Read the current `stable/v0.23` HEAD and compare it with dev before editing.
2. If stable has moved, bring the latest stable changes into dev first. Do not overwrite stable or resurrect the old dev tree. Resolve conflicts in favor of the tested stable audio/UI implementation unless a newer fix has been independently verified.
3. Add one isolated feature/fix to dev. All GitHub Actions IPA builds on dev verify that stable is an ancestor; they fail rather than shipping stale code.
4. Run CI and test on an iPhone. Stable promotion should be deliberate, only after playback and UI tests.
5. After a stable promotion, sync stable into dev again before the next feature.

## 2026-10-12 recovery

- Clean base: `stable/v0.23` at `03502ae5586602612f7268b78d1ab5ba5abad7e8`.
- Original unrelated dev history preserved at `archive/dev-v023-pre-stable-rebase-20261012`.
- Dev tree reconstructed directly from stable with selected logo, animation, performance and Sing fixes (the DJ Mix laboratory was later removed).
- Core stable audio source queue and pipeline implementation are byte-for-byte unchanged. **Do not restore old dev queue offsets or older Spotify 9.1.90 compatibility behavior.**
- DJ Mix and its optional build backend were removed from dev. The feature must not appear in the app or build workflow.

Stable is a moving base, not a frozen backup. A feature is only part of stable when it has been deliberately promoted and tested.

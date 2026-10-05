# Personal spoti.pw v0.23 project

This branch is Dhruv's personal experimental continuation of spoti.pw v0.23-beta.

## Safety branches

- `main` — current Chroma 0.50 patcher workflow. Do not repurpose it for v0.23 development.
- `archive/chroma-0.50` — snapshot of the Chroma 0.50 setup before this project started.
- `baseline/v0.23-beta` — exact upstream v0.23-beta commit. Never modify this branch.
- `stable/v0.23` — daily-use line. Only promote changes here after they work on-device.
- `dev/v0.23` — all experiments and active development happen here first.

The untouched v0.23-beta base commit is:
`49e02e204f397b1e4197876dd622d4ee1663188e`.

## Build workflow

Use GitHub Actions → **Build personal v0.23**.

Inputs:

- **source_branch**
  - `baseline/v0.23-beta`: stock comparison build
  - `stable/v0.23`: daily-use build
  - `dev/v0.23`: test the newest changes
- **ipa_url**: direct decrypted Spotify IPA URL
- **include_eevee**:
  - off = spoti.pw only
  - on = spoti.pw + EeveeSpotify
- **eevee_ref**: defaults to `v7.0.0`
- **upload_method**: GitHub artifact, Filebin, or both

The workflow detects the Spotify version. It does not intentionally hard-block newer 9.1.x versions.

When Eevee is enabled, the builder uses Eevee's current sideload shim and does not use cyan's extension-stripping flags, because spoti.pw's Live Activity extension must survive.

## Development rules

1. Never develop directly on `baseline/v0.23-beta`.
2. Never promote an untested dev change directly to stable.
3. Keep changes small enough that a regression can be traced to one feature/fix.
4. Prefer fixing duplicated Eevee/spoti.pw behavior rather than letting two implementations fight over the same Spotify UI.
5. Do not weaken or bypass Chroma 0.50 subscription/entitlement checks. This project works from the separately permitted v0.23 personal fork.
6. Do not commit decrypted Spotify IPAs, signing certificates, tokens, passwords, or private account data.

## Feedback loop

For each dev build, record:

- Spotify version
- iOS version
- spoti.pw branch/commit
- Eevee version, if injected
- what was enabled
- what happened
- exact reproduction steps
- whether the same issue exists on `baseline/v0.23-beta`

The dev branch adds **Mod → Copy diagnostics**. Use it after reproducing a UI issue, review the copied text for anything private, then paste it into the ChatGPT project.

## First milestones

1. Confirm stock `baseline/v0.23-beta` builds and launches.
2. Confirm `stable/v0.23` behaves identically before any promotions.
3. Confirm a `dev/v0.23` build launches.
4. Confirm v0.23 + Eevee v7 launches without removing the Live Activity extension.
5. Compare Eevee's Liquid Glass against v0.23 feature-by-feature and choose one owner for overlapping UI.
6. Profile startup, player opening, lyrics, artwork, and memory before performance changes.
7. Only then start larger feature work and newer-Spotify compatibility fixes.

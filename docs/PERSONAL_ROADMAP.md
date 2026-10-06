# Personal Spotify Roadmap — Listening Stats, Q20i Audio, and Apple Music Gaps

> Planning document only. No feature implementation is included here.
>
> Active personal build: `stable/v0.23`
>
> Goal: improve the daily listening experience without turning the fork into a feature dump or duplicating Eevee.

## 1. Product decisions

### Build / research next

1. **Listening Stats + Recap**
   - Local-first listening history and statistics.
   - Monthly, yearly, and all-time views.
   - A distinctive visual recap using Liquid Glass, album/track artwork, motion, gradients, and shareable cards.
   - Spotify Extended Streaming History import so historical stats do not start from zero.

2. **Soundcore Q20i audio profile**
   - Research and validate a Q20i-specific correction preset.
   - Use the existing spoti.pw audio-effects pipeline rather than adding a second audio engine.
   - Prefer a genuinely useful headphone correction over generic "spatial audio."

3. **Apple Music-inspired features that fit this fork**
   - Music Pins / quick-access shelf.
   - Better Replay-style insights.
   - Better lyrics translation/pronunciation UX where our lyric sources support it.
   - Discovery/history features built from our own listening database.

### Explicitly not planned

- DJ / AutoMix clone.
- AirPods head gestures.
- AirPods-style dynamic head tracking.
- Local-file features.
- Landscape lyrics.
- Full-screen lock-screen lyrics.
- Further Live Activity work.
- Temporary fast playback by holding artwork.
- Mini-player auto-collapse work.
- Hide-video-switch option.
- Custom app-wide fonts.
- Low Data Mode controls for animated artwork.
- Duplicating lyrics-control auto-hide if the current build already does it.

---

# 2. Listening Stats — product concept

## Objective

Build the listening-history feature Spotify should already have: always available, local, searchable, visually polished, and useful outside one annual Wrapped event.

The feature should have two modes:

- **Stats** — persistent dashboards for day/week/month/year/all time.
- **Recap** — a visual story generated from a selected period.

The underlying data should be the same. Recap is only a presentation layer.

## Data sources

### A. New listening captured on-device

The current fork already has a shared player-state layer (`Shared/Player/PlayerState`) so new stats should subscribe to that one source instead of adding another independent player hook.

Record enough information to calculate:

- track URI
- track title
- artist(s)
- album
- artwork reference/cache key where practical
- start time
- end time
- milliseconds actually listened
- context URI where available
- shuffle state
- completed vs skipped
- play source/reason if we can reliably obtain it without fragile hooks

Avoid high-frequency polling. Track elapsed listening using state transitions and timestamps, then reconcile at track/pause/end transitions where possible.

### B. Spotify Extended Streaming History import

Spotify officially provides lifetime Extended Streaming History in JSON. It can include track URI, track/artist/album names, milliseconds played, platform, shuffle state, skip information, start/end reason, offline state and private-session information.

Reference:
- https://support.spotify.com/in-en/article/understanding-your-data/

Import design:

1. User selects Spotify's downloaded ZIP/JSON files.
2. Parse locally.
3. Ignore podcast/audiobook records for the music statistics experience unless we later add a separate media section.
4. Deduplicate imported rows against existing local history.
5. Prefer Spotify Track URI as the identity.
6. Keep raw history plus derived daily/monthly aggregates.
7. Never upload listening history anywhere.

Suggested dedupe key:
`timestamp + Spotify URI + msPlayed`, with a fallback using title/artist for old records missing a URI.

## Counting rules

Keep **time listened** and **play count** separate.

Suggested first version:

- every valid session contributes to listening time;
- a "play" counts after 30 seconds;
- a completion is tracked separately;
- an early next-track action is a skip;
- replays count as separate sessions.

This avoids a five-second accidental play becoming equal to a fully played track.

Store the raw data so the calculation rules can change later without losing history.

---

# 3. Listening Stats — UI direction

## Design principle

Do **not** copy Spotify Wrapped screens.

Use the same idea — music data should feel emotional and visual — but make our own visual language:

**Liquid Glass + cover art + depth + movement + typography + personal data.**

The screen should feel like it belongs to our redesigned Spotify rather than like a web analytics dashboard.

## Entry point

Add a **Listening** / **Stats** page reachable from:

- Mod/custom tab system if the user wants it as a tab;
- a row inside the personal mod page;
- optionally a small "Your month" card on the redesigned Home page later.

No forced Home clutter in v1.

## Main Stats screen

### Hero

Large glass card over a blurred collage of the user's most-played cover art.

Example:

**October**
- 2,841 minutes
- 487 songs
- 163 artists

The art behind the card should come from the user's actual top albums/tracks for the period.

Below the hero:

- This week
- This month
- This year
- All time
- custom date range

Use native horizontal segmented controls / glass pills rather than a custom web-style selector.

### Top music sections

Each category should be artwork-heavy rather than a text table.

- Top Songs
- Top Artists
- Top Albums

Ideas:

- #1 item gets a large hero tile.
- #2–#5 overlap underneath as smaller covers.
- tapping opens the normal Spotify entity.
- glass rank badge floats over the artwork.
- amount listened / plays appears as secondary text.

## Insight cards

Cards should only show insights supported by actual data.

Examples:

### Your obsession
Artwork fills most of the card.

> You played "X" 37 times this month.

### Artist era

> 18% of your listening this month was Artist X.

### Peak day

> Saturday was your biggest listening day — 4h 12m.

### Night music

> 31% of your listening happened after midnight.

### Rediscovered

A track/artist heavily played now after not being heard for 90+ days.

### New discovery

An artist first heard during the selected period who became one of the most-played artists.

### Deep cut

A song repeatedly played from an album while not being one of that album's globally obvious singles, **only if we can determine this reliably**. Otherwise omit it.

### Listening clock

A circular 24-hour visualization showing when listening happens.

### Variety

- unique songs
- unique artists
- new artists
- repeat-listening ratio

Avoid fake personality labels unless the underlying calculation is transparent.

---

# 4. Recap / "Wrapped-like" experience

## Purpose

A recap should be generated for:

- month
- year
- custom date range

This makes it useful all year rather than once each December.

## Visual system

Original direction:

- edge-to-edge album artwork
- Liquid Glass cards floating over artwork
- soft artwork-derived background colours
- fluid transitions between covers
- subtle parallax
- bold large numerals
- minimal text
- SF Symbols only where they help
- animated cover art when already cached/available, static art otherwise

Spotify described 2025 Wrapped as a "visual mixtape" using bold imagery and layered texture. Our version should instead feel like a **personal glass music journal**.

Reference:
- https://newsroom.spotify.com/2025-12-03/wrapped-marketing-campaign/

## Proposed recap sequence

1. **Opening**
   - collage of the period's cover art
   - "Your October in music"

2. **Minutes listened**
   - one huge number
   - artwork slowly moves behind glass

3. **Top song**
   - full album artwork
   - play count + minutes

4. **Top artist**
   - artist image / album-art mosaic
   - total listening time

5. **Top album**

6. **Your five**
   - top five songs as stacked artwork cards

7. **Listening clock**
   - when the user listened most

8. **Discovery**
   - artists heard for the first time

9. **Obsession**
   - strongest repeat-listening period

10. **Final card**
    - 3x3 or 4x4 artwork mosaic
    - summary stats
    - export/share as image

Allow:
- tap forward/back;
- scrub to a recap page;
- replay one card instead of restarting;
- disable motion.

Spotify's 2025 Wrapped specifically improved revisiting moments and playback speed. We should retain the useful navigation idea without copying its visual design.

Reference:
- https://newsroom.spotify.com/2025-12-03/2025-wrapped-user-experience/

## Share cards

Generate a few static templates locally:

- Top 5
- Top artist
- Top song
- Month summary
- Year summary

Use album art and the fork's glass visual language.

No watermark other than an optional subtle spoti.pw mark.

---

# 5. Storage and performance plan

## Local database

Prefer SQLite or another small local persistent store.

Conceptual tables:

### plays
- id
- track_uri
- title
- artist_names
- album_name
- played_at
- ms_played
- completed
- skipped
- context_uri
- shuffle
- source
- import_source

### tracks
- track_uri
- last_known_title
- artist names / IDs where available
- album
- artwork reference
- first_seen
- last_seen

### daily_aggregate
- date
- listening_ms
- plays
- completed
- skipped
- unique_tracks
- unique_artists

Keep raw play events. Aggregates are caches that can be rebuilt.

## Performance rules

- no continuous background timer;
- no network requests solely to update statistics;
- reuse existing player-state observations;
- batch database writes;
- update aggregates incrementally;
- build expensive recap calculations when the Stats page is opened or after a listening session, not constantly;
- cap artwork cache separately from history data;
- disabled Stats feature should perform effectively no ongoing work.

---

# 6. Privacy

This feature should be deliberately more private than Wrapped-style cloud analytics.

Default:

- all history stays on the iPhone;
- imports are parsed locally;
- no statistics telemetry;
- no external analytics;
- allow "Delete listening history";
- optionally allow a private-session exclusion rule.

The raw Spotify export can contain IP addresses and other fields that this feature does not need. **Do not import or retain those fields.**

---

# 7. Soundcore Q20i research

## What the headphones support

Soundcore's current Q20i information lists:

- Hybrid ANC
- 40 hours battery with ANC / 60 hours normal
- Bluetooth multipoint
- customizable EQ in the Soundcore app
- 22 EQ presets
- BassUp
- Hi-Res certification over AUX

Official source:
- https://www.soundcore.com/products/q20i-a3004z31

## Sound character

Independent measurement/review material describes the Q20i as broadly U-shaped: elevated bass and treble relative to a neutral preference curve. That makes headphone correction more relevant than a generic spatializer.

Reference:
- https://www.techgearlab.com/reviews/audio/budget-headphones/soundcore-q20i

## AutoEQ status

A GitHub search of the main AutoEq repository did not surface a dedicated `Soundcore Q20i` profile during this research.

Therefore:

**Do not ship a random internet EQ and call it AutoEQ.**

Plan:

1. Find a reproducible Q20i frequency-response measurement dataset that we are allowed to use.
2. Determine which listening mode was measured (ANC / normal / wired).
3. Derive a correction curve against a chosen target.
4. Convert it to the filters supported by our existing DSP engine.
5. Verify clipping/headroom.
6. Test against the Soundcore app set to a known neutral/flat state.
7. Listen-test before putting it in stable.

Possible presets after validation:

- **Q20i Neutral**
- **Q20i Neutral + Bass**
- **Q20i Vocals**

The key is to avoid double-EQ. If Soundcore's own custom EQ is active at the same time, our correction may be stacked on top of it.

## Spatial audio and Q20i

Spatial audio is **not inherently AirPods-only**.

Apple Music can render Dolby Atmos to non-Apple headphones when Dolby Atmos is set to Always On, but Apple's dynamic head tracking is an AirPods/compatible-device feature.

Official Apple reference:
- https://support.apple.com/en-asia/guide/iphone/iphac459a29e/ios

For this Spotify fork, however:

- Spotify is providing a normal stereo music stream.
- A spatial feature we add would be DSP applied to stereo audio.
- It would **not** turn the stream into Apple Music's real Dolby Atmos mix.
- Q20i has no Apple-style dynamic head tracking integration.

Conclusion: **deprioritize spatial audio for now. Q20i correction / audio presets are more useful.**

---

# 8. Apple Music features — relevant gaps

Current Apple Music features include Replay insights, Music Pins, Lyrics Translation/Pronunciation, Discovery/personalized stations, collaborative playlists, AutoMix, Sing, Music Haptics, lossless and Dolby Atmos.

References:
- https://www.apple.com/in/apple-music/
- https://support.apple.com/en-az/109356
- https://support.apple.com/en-in/guide/iphone/iph1c41d7ea3/ios
- https://www.apple.com/in/newsroom/2025/06/apple-services-deliver-powerful-features-and-intelligent-updates-to-users-this-fall/

## Worth considering for our fork

### A. Music Pins — high priority

Apple Music lets users pin albums, artists, playlists and songs to the top of the Library.

Our version could be better:

- pin any Spotify entity;
- glass "Pinned" shelf at the top of Library;
- reorder by drag;
- choose tap action: Open / Play / Shuffle;
- keep it completely local so no Spotify server behavior needs to change.

This is small and likely useful every day.

### B. Replay-style stats — highest priority

Apple Music Replay provides monthly and year-end top songs/artists/albums plus milestones and shareable visual summaries.

Our Listening Stats plan should exceed this by adding:

- arbitrary periods;
- searchable history;
- lifetime import;
- listening clock;
- rediscoveries;
- completion/skip patterns;
- more artwork-driven recaps.

### C. Lyrics translation/pronunciation — medium priority

Apple Music exposes translation and pronunciation directly in Now Playing.

Our fork already has rich lyrics sources and some translation/pronunciation support. Rather than add another lyrics engine, improve the UX:

- one clear Translation button;
- one clear Pronunciation button;
- remember preference by language;
- optionally translate on demand only when no source provides a translation.

### D. Discovery Station-style page — research

Apple Music exposes a dedicated Discovery Station/personalized discovery experience.

Spotify already has stronger recommendation infrastructure, so do not build our own recommendation model.

Potential enhancement:
- a single **Discover** page combining Spotify's own useful discovery surfaces while removing clutter;
- "new to me" filter using local listening history;
- hide anything already played heavily;
- "from artists I already like" vs "completely new" filters.

This lets Spotify choose the songs while our local stats make the feed smarter for the user.

### E. Collaborative playlists — no priority

Spotify already supports collaborative playlist behavior. There is no reason to recreate this merely because Apple Music has it.

### F. AutoMix — explicitly excluded

Apple's AutoMix uses time stretching and beat matching. The DJ/transition direction has already been rejected for this fork.

### G. Lossless / Dolby Atmos — not a fork priority

These depend on the source audio supplied by the streaming service. They are not something a client-side tweak can honestly recreate from a normal Spotify stream.

---

# 9. Additional features likely to fit this build

These ideas deliberately build on listening history rather than adding random controls.

## 1. Searchable listening history

Examples:

- "What was that song I played yesterday?"
- filter by date
- filter by artist
- filter by album
- search title
- jump straight back into the track

This becomes nearly free once the Stats database exists.

## 2. Forgotten favourites

A generated page of tracks that:

- were played heavily before;
- have not been played for 60/90/180 days.

Sort by previous play count.

## 3. "On this month" music memory

Show what dominated listening:

- one month ago;
- six months ago;
- one year ago.

Cover-art-first presentation.

## 4. Recent obsessions

A rolling list of tracks/artists whose listening increased sharply in the last 7/30 days.

This is more useful than a static top list.

## 5. New Release Inbox

One clean chronological feed for releases from followed/favourite artists.

Goal:
- no podcast cards;
- no sponsored-style clutter;
- no recommendation soup;
- simply "artists you care about released these."

Needs separate feasibility research against Spotify's available data before implementation.

## 6. Pinned music shelf

The Apple Music-inspired feature above.

This is likely the best small feature to implement after Stats.

## 7. Resume an album

Remember the last meaningful position in an album and offer:

> Continue album — Track 6 of 13

Do not interfere with normal Spotify playback. It is simply a local shortcut.

## 8. "New to me" indicator

Using local/imported history:

- mark a song/artist as first-time;
- optionally show a small badge in discovery contexts;
- can power recap data without changing recommendations.

## 9. Personal milestones

Examples:

- 100th play of a track
- 10 hours with an artist
- 1,000 unique songs
- 100 new artists this year

Keep them subtle and optional rather than notification spam.

---

# 10. Priority roadmap

## Phase 1 — Listening data foundation

1. Define event schema.
2. Capture reliable new plays from the existing shared player state.
3. Build local database.
4. Build Extended Streaming History importer.
5. Validate deduplication and duration calculations.

## Phase 2 — Stats UI

1. Period selector.
2. Hero summary.
3. Top songs/artists/albums.
4. Listening timeline / clock.
5. Searchable history.

## Phase 3 — Recap UI

1. Monthly recap.
2. Year recap.
3. Artwork-heavy Liquid Glass story.
4. Share/export cards.
5. Motion and accessibility settings.

## Phase 4 — Q20i

1. Obtain reliable measurements.
2. Design correction.
3. Add Q20i presets to existing audio effects.
4. Device listening test.
5. Compare ANC / Normal behavior.

## Phase 5 — small experience features

Priority order:

1. Music Pins / pinned shelf.
2. Forgotten Favourites.
3. Recent Obsessions.
4. "On this month" memories.
5. Resume an album.
6. New Release Inbox feasibility.
7. Better lyrics translation/pronunciation controls.

---

# 11. Success criteria

Listening Stats is successful if:

- it records history without affecting playback;
- disabled means effectively zero ongoing work;
- imported Spotify history reconciles cleanly with new local history;
- the Stats page opens quickly even with years of data;
- the recap feels personal because it uses actual cover art rather than generic charts;
- no private listening data leaves the phone;
- calculations are explainable;
- the feature adds value every month, not only at year end.

The target is **"a private Apple Replay / Spotify Wrapped that lives inside Spotify all year"**, designed in the visual language of this fork.

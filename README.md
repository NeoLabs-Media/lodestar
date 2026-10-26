<div align="center">

# ✦ Lodestar

**Tell it what you've watched. It finds what to watch next, including the gems nobody recommends.**

[**Open the web app →**](https://neolabs-media.github.io/lodestar/) · macOS · iOS · Web

<sub>Anime, movies and series.</sub>

</div>

---

## Why you'll like it

| | |
|---|---|
| **It asks *why*** | Rate a title, then tap what worked: *slow-burn romance*, *bittersweet ending*, *found family*… Tap twice to **dislike** a tag instead (even on a show you loved) and it vanishes from your feed. |
| **Hidden gems on a dial** | One switch takes you from popular picks to deep cuts. Every card explains itself: "like *Your Lie in April*, which you rated 9.5". |
| **Private by design** | No account, no tracking, no server of ours. Your ratings live on your device (or in your browser). |
| **Optional assistant** | Off by default. Add your own OpenRouter key and ask in plain language ("something like *Monster* but lighter"). It searches this catalog with tools, never invents titles, hides spoilers unless you flip the switch, obeys your filters, and only reads your library if you allow it. Changes to your list always wait for your tap. |

## How it works

1. **Add what you've seen**: search, paste a list, import a file, or pull your whole Crunchyroll history with one bookmark click (no password, no extension).
2. **Rate and say why**: a few seconds per title.
3. **Get a feed of unwatched picks**: filter by media type, category and mood, plus options that fit what you're browsing (anime: format, episodes, studio · movies: runtime, decade, director, country · TV: seasons, status, network). Each type remembers its own filters.
4. **Check your taste profile**: a plain-language summary that updates as you rate.

## The catalog

Every title carries a hand-built *deep profile*, not just tags:

- **45 scored dimensions** (slow-burn, tragedy, moral ambiguity, pacing…) plus ~900 themes, moods and archetypes
- **Characters, relationships, spoiler-free pitch, ending type** and a 384-d text embedding
- **31,000+ titles shipped today**: ~15.8k anime, ~12.6k movies and ~3k TV series, every one with its own full profile (the 4,400 most popular anime get the extended 7-pass analysis)

> **The flex:** profiling the catalog took ~**840 million tokens**. At premium API rates that's a small-car invoice, call it **$15k and then some**. We ran it on our own hardware instead. No neural network was harmed in the making of this recommender: it's embeddings, ridge regression and a diversity re-rank, all running locally.

## Run it

```bash
flutter pub get
flutter run -d macos        # or: -d chrome · ios
flutter test                # engine tests: personas, leave-one-out, search, categories
```

Web build (what the GitHub Pages workflow runs):

```bash
flutter build web --release --pwa-strategy=none --base-href /lodestar/
```

<sub>Metadata courtesy of AniList, Kitsu and Wikipedia; covers load from their original hosts.</sub>

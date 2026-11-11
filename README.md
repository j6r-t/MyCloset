# MyCloset

A personal, Android-only wardrobe app built with Flutter. Photograph your clothes,
remove the background entirely on-device, organize them into a closet, build outfits
on a flat-lay canvas, and get color-harmony-based suggestions for what to wear.

Everything runs locally — no backend, no accounts, no cloud storage.

## Features

- **Capture** — take or import a photo of a garment.
- **On-device background removal** — U2-Netp segmentation running locally via TFLite,
  with a manual eraser/restore brush for touch-ups.
- **Auto-fill item details** — category, color, and pattern are identified automatically
  (fully on-device; optional online lookup via Google Cloud Vision / SerpAPI Lens,
  off by default).
- **Wardrobe** — browse and filter your items by category, color, season, and condition.
- **Outfit builder** — compose outfits on a flat-lay canvas, layering pieces in order.
- **Suggestions** — color-harmony engine proposes outfit combinations from your wardrobe.
- **Backup / restore** — export and reimport your full closet as a single archive.

## Tech

- Flutter (Android only)
- Drift (local SQLite database)
- TFLite with U2-Netp for portrait segmentation
- Palette-based color extraction and harmony math

## Getting started

Requirements: the [Flutter SDK](https://docs.flutter.dev/get-started/install) with
Android tooling set up.

```sh
flutter pub get
flutter run
```

## Project structure

```
lib/
  screens/    one file per screen (capture, wardrobe, outfit builder, ...)
  services/   segmentation, color extraction, identification, suggestions, backup
  database/   Drift schema and queries
  models/     item and outfit data models
  widgets/    shared UI components
  ui/         theme, app shell, global state
assets/
  models/     U2-Netp TFLite model
  data/       named-color palettes
```

## Documentation

Deeper design and engineering notes live in `docs/`, read in this order:

1. [`docs/handoff.md`](docs/handoff.md) — what this project is, decisions log, constraints
2. [`docs/design.md`](docs/design.md) — visual direction, design system, screen specs
3. [`docs/userFlow.md`](docs/userFlow.md) — every user journey, step by step
4. [`docs/backend.md`](docs/backend.md) — DB schema, image pipeline, color extraction, suggestion engine
5. [`docs/plan.md`](docs/plan.md) — build plan and phase breakdown

## Status

Personal project, in active development. Core loop (capture → cutout → wardrobe →
outfits → suggestions) is working; see `docs/plan.md` for what's next.

# MyCloset

A personal, offline-first wardrobe app for Android, built with Flutter.

Photograph your clothes, remove the background entirely on-device, organize
them into a closet, build outfits on a flat-lay canvas, and get
color-harmony-based suggestions for what to wear. Everything runs locally —
no backend, no accounts, no cloud storage.

![Flutter](https://img.shields.io/badge/Flutter-Android-02569B?logo=flutter&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3-0175C2?logo=dart&logoColor=white)

---

## Table of contents

- [Features](#features)
- [Download](#download)
- [Building from source](#building-from-source)
- [Usage guide](#usage-guide)
- [Online identification & API keys](#online-identification--api-keys)
- [Privacy](#privacy)
- [Tech](#tech)
- [Project structure](#project-structure)
- [Documentation](#documentation)
- [Status](#status)

## Features

- **Capture** — take or import a photo of a garment.
- **On-device background removal** — U²-Netp segmentation running locally via
  TFLite. No upload, no server: the cutout is produced on the phone.
- **Eraser / restore brush** — touch up the cutout by hand, with Size,
  Opacity and Hardness controls, a live stroke preview pad, and a feathered
  brush indicator on the canvas. Undo the last 5 strokes.
- **Auto-fill item details** — category, colors and pattern are identified
  automatically on-device. Optionally, an online lookup (Google Lens via
  SerpApi + Cloud Vision) can prefill name, brand, type, size and price —
  off by default, empty fields only, your own input always wins.
- **Wardrobe** — browse and filter your items by category, color, season and
  condition, with a per-category value chart.
- **Outfit builder** — compose outfits on a flat-lay canvas, layering pieces
  in order (inner → both → outer).
- **Suggestions** — a color-harmony engine proposes outfit combinations from
  your wardrobe, with plain-language reasons ("Navy + white: classic pair").
- **Backup / restore** — export your full closet (database + images) as a
  single archive and reimport it on any device.
- **Dark mode** — full light/dark/system theming.

## Download

Grab the latest APK from the
[**Releases**](https://github.com/j6r-t/MyCloset/releases/latest) page and
install it on your Android phone (you will need to allow installs from
unknown sources, since it is not on the Play Store).

## Building from source

Requirements: the [Flutter SDK](https://docs.flutter.dev/get-started/install)
with Android tooling set up.

```sh
git clone https://github.com/j6r-t/MyCloset.git
cd MyCloset
flutter pub get
flutter run            # debug, on a connected device/emulator
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```

## Usage guide

The app walks you through one flow for every new garment:

1. **Capture** — photograph a garment on a plain-ish background, or import
   one from your gallery.
2. **Review the cutout** — the background is removed on-device. If edges
   need cleanup, open the **eraser**: pick Erase or Restore, adjust
   **Size (px)**, **Opacity (%)** and **Hardness** (100% = crisp edge, lower
   = feathered), and check the preview pad to see exactly how a stroke will
   look. **Undo** backs out your last strokes.
3. **Identification** — if you set API keys (see below), the app looks the
   garment up online here and shows what it found. Without keys it skips
   straight to the form.
4. **Details form** — fields found by the search (name, brand, type, size,
   price) are prefilled and marked with a brief "auto" chip; anything you
   type yourself is never overwritten. Pick garment type, color(s), season,
   condition, fabric and value, then **Save item**.
5. **Wardrobe** — your full closet, filterable and browsable.
6. **Outfits** — build outfits on the flat-lay canvas, or let the
   **Suggestions** tab propose combinations with color-harmony reasoning.

**Settings** also offers theme selection, backup export/restore, and the
online-identification keys.

## Online identification & API keys

The online lookup is **entirely optional** — every core feature works
without it. When enabled, it runs once per new item, right after the cutout
review:

1. **Google Lens via SerpApi** — finds matching products; from the results
   the app derives name, brand, garment type, size and (via Google
   Shopping) a price suggestion.
2. **Cloud Vision (fallback)** — only used when Lens finds nothing.
3. Nothing found: the details form simply opens empty, with the reasons
   shown.

### Where to enter the keys

In the app: **Settings → Online identification**. Two fields:

- **SerpAPI key** — the one that powers the whole lookup. Recommended.
- **Cloud Vision key** — optional fallback; add it only if you want the
  extra step.

### How to get a SerpAPI key (free tier available)

1. Go to [serpapi.com](https://serpapi.com) and sign up for a free account.
2. The free plan includes **100 searches per month** — no credit card
   required.
3. Your API key is shown on your
   [dashboard](https://serpapi.com/manage-api-key) under *API Key*.
4. Copy it and paste it into **Settings → Online identification → SerpAPI
   key**.

> Note: each identification uses one Lens search plus one Shopping search,
> so the free tier covers roughly 50 identifications per month.

### How to get a Cloud Vision key (optional)

1. Open the [Google Cloud Console](https://console.cloud.google.com) and
   create (or select) a project.
2. Enable the **Cloud Vision API** (*APIs & Services → Library*).
3. Go to *APIs & Services → Credentials* → **Create credentials → API key**.
4. Copy the key and paste it into **Settings → Online identification →
   Cloud Vision key**.

Google grants a free monthly allowance (1,000 units) that comfortably
covers personal use.

### Key handling

Keys are stored **only** in the app's local database on your device. They
are never logged, never written anywhere else, and sent only to the service
each one belongs to. To remove a key, save an empty field.

## Privacy

- No account, no server, no analytics. Your closet never leaves your phone.
- The **only** networked feature is the opt-in identification above, and it
  sends exactly one image (downscaled to 512 px) per lookup — never your
  database, never your other photos.
- Backups are manual, local zip files. Keep yours somewhere safe.

## Tech

- Flutter (Android only), Dart 3
- Drift (local SQLite database), schema migrations tested
- TFLite with U²-Netp for background segmentation
- Mask post-processing (despeckle, feathering) in pure Dart
- Palette-based color extraction and color-harmony math
- SerpApi (Google Lens / Shopping) + Google Cloud Vision for the optional
  online lookup

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

Personal project, in active development. The core loop (capture → cutout →
wardrobe → outfits → suggestions) is complete and used daily by the author;
see `docs/plan.md` for what's next.

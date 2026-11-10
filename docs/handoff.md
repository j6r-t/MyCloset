# MyCloset — Project Handoff / Context

> Read this first. It is the single source of truth for what this project is, what was decided, and what was deliberately left out. Update it whenever a decision changes.

## Current status (2026-11-10)

- **MVP v1 built and green** (all agents done; analyze 0 issues; tests passed; APK built).
- **Wada palettes integrated**: all 348 combinations from espectro.dev baked into `assets/data/palettes.json` (offline, no runtime API).
- **v2 redesign COMPLETE and green** (Fitted-minimal direction, `design.md` v2):
  - ✅ Backend schema v2 migration (size + layer_type, engine outer-layer rule, backup-validation fix).
  - ✅ Frontend rebuild: bottom pill nav + FAB, dashboard value headline + category bars, seamless label-free grid, vertical flat-lay outfit columns, Size/Layer Type persisted through AppState.
  - ✅ Verify: `flutter analyze` clean, **55/55 tests pass**, debug APK builds, zero v1 artifacts (no serif/cream/gold/google_fonts/emojis).
  - ✅ **On-device segmentation implemented (2026-11-10)**: `assets/models/u2netp_320.tflite` (2.4MB U²-Netp, flatbuffer-verified 7-output structure), `TFLiteSegmentationService` + pure-Dart `mask_postprocessing.dart` (threshold 0.5 → despeckle → feather → alpha). All failure paths degrade to keep-the-original. **67/67 tests green, APK builds.** Real-world quality validation on a phone still pending (user's manual test — incl. the colorful-rock-floor case). Tuning knobs if needed: threshold constant, despeckle fraction, or swap to the official 88MB model (see backend.md §3.2).
- Nothing committed to git yet (awaiting user request).

## What this is

A **personal-use, Android-only** wardrobe app built in **Flutter** by a solo beginner developer. You photograph your clothes, the app removes the background **on the phone** (no server), stores each item with metadata (brand, price, colors, category, season…), lets you assemble outfits manually, and suggests outfit combinations based on **color-harmony theory** (inspired by *A Dictionary of Color Combinations*, Sanzō Wada — the user owns the book; transcribing its palettes for **private use** is fine) and clothing type.

## Hard constraints (do not violate)

| Constraint | Consequence |
|---|---|
| Android only, personal use | No iOS, no app store, no signing-for-play. Deliverable = sideloaded release APK. |
| No backend, no login | All data local: SQLite DB + image files on the phone. No accounts, no sync in MVP. |
| No emojis in the UI | Use icon fonts (Material Symbols) or real images only — everywhere. |
| Solo beginner developer | Prefer simple, well-documented choices over clever ones. Fewest packages that work. |

## Decisions log

| Date | Decision |
|---|---|
| 2026-11-09 | Flutter over React Native / native (beginner-friendly, one codebase) |
| 2026-11-09 | Personal-use only → local storage, no backend, no auth |
| 2026-11-09 | Background removal: **on-device TFLite segmentation model** (not server rembg, not flood-fill) |
| 2026-11-09 | Outfit slots: **all 6** — top, bottom, dress, shoes, outerwear, accessory |
| 2026-11-09 | Testing: real phone over USB; Android Studio only as SDK/emulator toolchain; code in VS Code |
| 2026-11-09 | Visual direction: **Editorial / fashion magazine** (see `design.md`) |
| 2026-11-10 | **Visual direction REPLACED**: white/gray/black minimalism inspired by the Fitted app (reference screenshots in `fitted_reference/`), system fonts, bottom pill nav + FAB, frameless cutouts, vertical flat-lay outfit columns. Rejected from reference: gamification, virtual try-on, social/shop features. Schema v2: +size, +layer_type (Times Worn explicitly rejected) |
| 2026-11-09 | Not a startup (for now) — architecture kept cheap to flip later (local-first converts cleanly to sync+auth) |

## Deliberately OUT of scope (backlog — do not build now)

- ⚠️ **Internet product-data lookup** (brand/price/type auto-fetch) — explicitly deferred by the user; revisit after MVP. Realistic options then: brand autocomplete, pasting a product URL, or a vision-LLM identification step.
- Weather-aware suggestions
- Wear-count / statistics
- Cloud backup or sync (an "export backup zip" button is in MVP; full sync is not)
- iOS, app store, monetization

## Key documents

- `../PLAN` summary of phases lives in the session plan file; roadmap recap below.
- `design.md` — visual direction, design system, screen specs
- `userFlow.md` — every user journey step by step
- `backend.md` — despite the name, this is the **local logic**: DB schema, image pipeline, color extraction, suggestion engine

## Roadmap recap (solo, part-time)

1. **Phase 0 — Setup:** Flutter SDK + Android Studio toolchain + VS Code; `flutter doctor` green; app runs on phone via USB.
2. **Phase 1 — Wardrobe core:** DB, add-item flow, on-device segmentation (hardest milestone — budget extra time), color extraction, grid + detail screens.
3. **Phase 2 — Outfits:** outfit builder, storage, suggestion engine + transcribed book palettes.
4. **Phase 3 — Polish:** cutout eraser brush, icon/splash, signed release APK, 2-week daily-driver trial.

## Environment notes

- Windows 11. Flutter already present at `C:\flutter\bin`. JDK 21 present. Android SDK dir exists at `%LOCALAPPDATA%\Android\Sdk` — verify `flutter doctor` passes.
- Phone testing needs USB debugging enabled (Developer options).

## Things that are easy to forget

- **Backup:** the SQLite file + images folder ARE the wardrobe. A lost phone loses everything. MVP includes an export-backup-zip button.
- **Secondary color per item** (stripes/plaid) — captured at add-time, used as a tiebreaker by the suggestion engine.
- **Suggestion transparency:** every suggestion shows a one-line reason ("navy + mustard: complementary accents"). Users trust what they can read.
- **Prototype the harmony rules in a spreadsheet before coding them.**

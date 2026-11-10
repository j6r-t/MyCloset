# MyCloset — Personal Digital Wardrobe App: Plan

## Context

Build an **Android-only, personal-use** wardrobe app: photograph clothes, remove the background **on-device**, store each item with metadata (brand, price, color, type…), build outfits manually, and get suggestions based on color-combination theory (inspired by the Sanzō Wada color dictionary the user owns — fine to transcribe palettes for private use) and clothing type.

**Decisions made:**
- Solo developer (beginner) — no team tasks
- Flutter, one codebase; **no iOS, no app store** — the app runs locally on the user's phone (sideloaded release APK)
- **No backend, no login** — all data lives on the phone
- Background removal: **on-device AI model** (TFLite)
- Outfit slots: **full 6 types** (top, bottom, dress, shoes, outerwear, accessory)
- Testing: real phone over USB, emulator occasionally
- Not a startup (for now) — keep architecture cheap to change if that ever flips

---

## Architecture (local-only)

```
Flutter app (Android)
 ├─ UI layer: wardrobe grid, add-item flow, outfit builder, suggestion screen
 ├─ Logic layer (Dart):
 │   ├─ color extraction (k-means on cutout pixels → primary + secondary hex)
 │   ├─ suggestion engine (color harmony + category + season rules)
 │   └─ palette data (transcribed from the book + named-color list)
 ├─ Storage:
 │   ├─ SQLite (drift package) — items, outfits, outfit_items tables
 │   └─ app documents dir — original photos + cutout PNGs
 └─ ML: U2Net-style segmentation model via tflite_flutter → cutout PNG
```

**Data model:**
- `items` (id, image_path, cutout_path, category ∈ {top, bottom, dress, shoes, outerwear, accessory}, subtype, brand, price, color_primary_hex, color_secondary_hex, season ∈ {summer, winter, all}, fabric, notes, created_at)
- `outfits` (id, name, created_at)
- `outfit_items` (outfit_id, item_id, slot)

**Add-item flow:**
1. Take photo (or pick from gallery) → 2. on-device model cuts background → 3. user sees cutout: accept / retake / erase leftovers with a brush → 4. auto-extract primary + secondary color (editable) → 5. optional metadata form → saved locally.

---

## MVP scope

- Add item: photo → cutout (with fix screen) → colors → metadata → saved
- Wardrobe grid, filterable by category / color / season
- Item detail: view + edit all fields, delete
- Outfit builder: pick items per slot (dress replaces top+bottom), save, gallery of saved outfits
- "Suggest" button: top-3 outfit suggestions with a one-line reason per combo

**Explicitly NOT in MVP:** product lookup from the internet (⚠️ **user-requested reminder — revisit later**), weather features, statistics, backup/sync.

---

## Suggestion engine (the interesting part)

1. Build candidates respecting slots (dress OR top+bottom + shoes; outerwear/accessory added if tagged)
2. Score color harmony between item primaries in HSL space: complementary, analogous, split-complementary, triadic, neutral+accent — plus the book's transcribed palettes as a "known-good pairs" bonus score
3. Penalize: 3+ saturated colors, two loud primaries, season mismatch
4. Return top 3 with reason lines ("navy + mustard: complementary accents")

Prototype this in a spreadsheet/notebook **before** coding it — cheap validation of the rules.

---

## Roadmap (solo, ~10–12 weeks part-time)

**Phase 0 — Setup (week 1):** Install Flutter SDK, Android Studio (SDK + emulator only — write Dart in VS Code), Python not needed anymore. `flutter create`, run on emulator, then on phone over USB. Project layout: `lib/models`, `lib/screens`, `lib/services`, `lib/data`.

**Phase 1 — Wardrobe core (weeks 2–5):** SQLite schema (drift), add-item flow with camera (`image_picker`), on-device segmentation model integration (the project's hardest milestone — budget extra time), color extraction, wardrobe grid + item detail.

**Phase 2 — Outfits (weeks 6–8):** Outfit builder UI, outfit storage, suggestion engine + palettes from the book.

**Phase 3 — Polish (weeks 9–10):** Fix-cutout eraser brush, app icon/splash, build signed release APK, sideload to phone, daily-driver trial for 2 weeks and fix what annoys you.

**Backlog (post-MVP):** internet product lookup (reminder above), weather-aware suggestions, wear-count stats, optional cloud backup (that's the day a backend re-enters the design).

---

## Setup checklist (Windows)

1. Flutter SDK + PATH; `flutter doctor` green for Android toolchain
2. Android Studio → SDK Manager → Android SDK + one AVD (emulator)
3. VS Code + Flutter/Dart extensions
4. Enable USB debugging on the phone (Developer options)
5. Get a U2Net TFLite model file (convert from open-source U2Net checkpoints, or use an existing converted segmentation model) into `assets/`
6. Git: commit early and often; `main` + feature branches even solo — free undo history

## Things worth knowing (adjusted for personal scope)

- **No privacy policy, no store fees, no accounts** — the app-store burden disappears entirely. Sideloaded APK is fully legitimate for personal use.
- **Backup your data anyway:** SQLite file + image folder are your whole wardrobe — a lost/bricked phone loses everything. Cheap insurance: occasional manual copy to PC (or an "export backup zip" button later).
- **Model size/latency:** keep the TFLite model ≤ ~5MB and run inference on downscaled images (~512px) — phones handle that fine.
- **Keep the MVP boring:** new ideas go on the backlog file, not into Phase 1.
- **If the startup idea ever comes back:** local-first architecture like this converts cleanly — sync + auth can be added around the same data model. Nothing here is wasted.

## Verification (end of MVP)

- Photograph 10 real clothing items on the phone → cutouts acceptable, colors detected ≈ correct
- Filter the wardrobe by category and color; edit an item's price and see it persist across app restarts
- Create one outfit manually; generate suggestions on a 20+ item wardrobe and judge whether top pick is wearable
- Kill the app mid-flow, reopen — no corrupted DB (drift migrations intact)

## Open items

- ⚠️ **Product-data lookup from the internet** — deferred by user request; revisit after MVP. For personal use, realistic options then: manual entry with brand autocomplete, or pasting a product URL / running a vision-LLM identification step.
- Which U2Net conversion path (pre-converted model vs. converting yourself with Python once) — decide at Phase 1 start.
- Exact palette transcription workflow from the book (photo pages → hex values; the book includes RGB values, so it's manual but straightforward).

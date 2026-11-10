# MyCloset — User Flows (userFlow.md)

Every journey a user (you) can take, step by step. Screen names match `design.md` §6. Logic references point to `backend.md` sections.

## Global structure

**Bottom pill nav (v2):** four preserved-state tab roots — **Wardrobe · Outfits · Suggest · Settings** — in a floating white pill, plus a black circular **+** FAB that starts the add-item flow from anywhere. Each tab keeps its scroll/state when switched (IndexedStack). Pushed screens (capture, cutout review, details, item detail, builder, picker) still open on top of the current tab; back arrow returns one level; state is never lost mid-flow.

```
Wardrobe (home)
 ├─ Add item ──► Capture ──► Cutout review ──► Details ──► (back to grid, new tile highlighted)
 ├─ tap ItemTile ──► Item detail ──► Edit / Delete
 ├─ Outfits (from section header) ──► Gallery ──► Outfit builder / Outfit detail
 └─ Suggest (shuffle button) ──► Suggestions ──► Save as outfit
Settings (gear, app bar)
```

## Flow 1 — First launch

1. Wardrobe screen opens with empty state: "Your closet is waiting." + ghost button "Add your first piece".
2. Tapping it starts Flow 2. No onboarding carousel, no permissions wall up front — camera permission is requested at the moment of first capture (Flow 2 step 1), storage at first gallery pick.

## Flow 2 — Add an item (the core loop, must be frictionless)

1. FAB → Capture screen. Choose: Take photo / Choose from gallery.
2. Photo taken/picked. **Processing** (see `backend.md` §3): tile shows shimmer placeholder ~1–3s while the on-device model cuts the background.
3. **Cutout review** (see `backend.md` §3.4): cutout displayed large on tile background.
   - Looks clean → Continue.
   - Leftover background pixels → toggle Eraser, drag over them, Continue.
   - Unusable → Retake (back to step 1; nothing saved yet).
4. **Details screen**: name (only required field); category of 6 (top, bottom, dress, shoes, outerwear, accessory — choosing dress auto-marks it as a one-piece for outfit logic); auto-extracted primary/secondary color swatches shown, tap to correct from a named-color list; optional: subtype, brand, price (TND), season (summer/winter/all), fabric, notes.
5. Save → back to Wardrobe, new tile briefly highlighted (accent border fade, 1s). Cancel at any point discards the draft images (deleted from disk, no orphans).

## Flow 3 — Browse & find

1. Wardrobe grid, default sort: newest first.
2. Filter chips: category (single-select), season, color dots (multi-select, matched on primary OR secondary).
3. Optional search field (name + brand). Filters combine with AND; active filters shown as chips in place; "clear" chip appears when any filter is active.
4. Result count caption updates live ("12 items").

## Flow 4 — Item detail

1. Tap tile → detail: large cutout, name (Cormorant), all metadata rows.
2. Edit → same form as Flow 2 step 4, pre-filled → Save.
3. Delete → confirm sheet ("Remove white tee from your closet? This can't be undone.") → item + its images deleted; if it belongs to outfits, those outfits show the slot as empty ("missing item") on next open.

## Flow 5 — Build an outfit manually

1. Outfits gallery → "New outfit" → Builder.
2. Slots shown as SlotCards: [Dress] ── or ── [Top + Bottom], then Shoes, Outerwear (collapsible), Accessory (collapsible).
3. Tap a slot → item picker filtered to that category (reuses Flow 3 filters) → tap item → back in builder.
4. Choosing Dress empties Top/Bottom automatically (and vice versa).
5. Live harmony readout updates with each slot ("Harmonious", "Mixed", "Clashing") — computed per `backend.md` §5.
6. Name (optional — defaults to "Outfit · Nov 9") → Save → gallery.

## Flow 5b — Outfit detail (added 2026-11-10)

Tap any outfit in the gallery → detail screen: full vertical flat-lay column (dashed placeholder if the core is missing), name (tap to rename inline), date + live harmony readout, then a **Pieces list** — one hairline row per garment (thumbnail, name, slot/size/layer-type, brand, price in money-green, color swatch). Tap a row → item detail; pencil → edit form; per-row delete → confirm → removes that slot from the outfit (outfit keeps its other pieces). Outfit-level actions: "Edit in builder" (black pill) and Delete (outlined, confirmed).

## Flow 6 — Get suggestions

1. Wardrobe → Suggest (shuffle icon in section header).
2. Engine builds candidates from full wardrobe (`backend.md` §5), returns top 3 as outfit cards, each with its one-line reason.
3. Shuffle regenerates (excludes previously shown combos until the pool is exhausted, then resets).
4. Save any card as an outfit (one tap) → Flow 5 gallery.

## Flow 7 — Backup / restore (Settings)

1. Settings → "Export backup": zips SQLite DB + all images → share sheet → save to Drive/PC.
2. "Restore": pick a backup zip → validation → replaces current data after confirm ("This replaces your current closet — N items will be removed.").

## Error & edge behaviors (apply everywhere)

- Processing fails or model errors → toast "Couldn't process this photo — try another angle" + option to keep the original image as-is (no cutout, still usable).
- Empty results after filtering → in-grid empty state ("Nothing matches — clear filters?") with one-tap clear.
- Deleting an item referenced by an outfit → outfit keeps its name, shows a dashed empty slot; suggestion engine skips incomplete outfits.

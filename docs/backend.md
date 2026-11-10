# MyCloset — Local Logic (backend.md)

There is **no server**. "Backend" here means everything that runs inside the app: storage, the image pipeline, color extraction, and the suggestion engine. Each feature is specified end-to-end so implementation is mechanical.

## 1. Stack & packages (keep minimal)

| Concern | Choice | Package |
|---|---|---|
| Framework | Flutter (Android-only target) | — |
| DB | SQLite via drift (typed, migrations) | `drift`, `drift_flutter` |
| Photo capture / pick | `image_picker` | |
| ML inference | TFLite segmentation | `tflite_flutter` |
| Image decode/resize/pixels | `image` (pure Dart) |
| Fonts | Cormorant Garamond + Inter | `google_fonts` |
| Icons | Material Symbols Outlined | `material_symbols_icons` |
| Paths | app documents dir | `path_provider` |
| Backup zip | `archive` + `share_plus` |
| State | plain `StatefulWidget` + `ChangeNotifier` until it hurts — no Riverpod/Bloc for MVP |

## 2. Storage layer

### 2.1 Database (drift)

```sql
items (
  id INTEGER PK AUTOINCREMENT,
  name TEXT NOT NULL,                -- optional in UI; defaults to 'Piece #<id>'
  category TEXT NOT NULL CHECK (category IN ('top','bottom','dress','shoes','outerwear','accessory')),
  subtype TEXT,                -- 't-shirt', 'jeans', 'blazer'…
  brand TEXT,
  price REAL,                  -- TND
  size TEXT,                   -- v2: 'XS'…'XL', numeric, free text
  layer_type TEXT CHECK (layer_type IN ('inner','outer','both')),  -- v2: null except top/outerwear
  season TEXT NOT NULL DEFAULT 'all' CHECK (season IN ('summer','winter','all')),
  fabric TEXT,
  notes TEXT,
  color_primary_hex TEXT NOT NULL,   -- '#1C2B4A'
  color_primary_name TEXT,           -- 'navy'
  color_secondary_hex TEXT,          -- nullable
  color_secondary_name TEXT,
  image_path TEXT NOT NULL,          -- original, app documents dir
  cutout_path TEXT NOT NULL,         -- RGBA PNG
  created_at INTEGER NOT NULL
)
outfits (id PK, name TEXT NOT NULL, created_at INTEGER NOT NULL)
outfit_items (outfit_id FK, item_id FK, slot TEXT, PRIMARY KEY (outfit_id, slot))
  -- slot ∈ {dress, top, bottom, shoes, outerwear, accessory}
  -- invariant enforced in code: dress present ⟺ top & bottom absent
```

Indexes: `items(category)`, `items(season)`. Delete item → delete its `outfit_items` rows (outfit keeps the slot empty; see `userFlow.md` edge behaviors).

**Migration v1→v2 (2026-11-10):** `ALTER TABLE items ADD COLUMN size TEXT` and `ADD COLUMN layer_type TEXT` (+ CHECK enforced at app level since SQLite can't add CHECK via ALTER). Engine rule added: a `top` with `layer_type` `outer` or `both` may also fill the outerwear slot in candidate generation.

### 2.2 File layout

```
<documents>/images/{item_id}/original.jpg    -- max 1600px long edge, JPEG q85
<documents>/images/{item_id}/cutout.png
<documents>/backups/closet_backup_<date>.zip
```

Save DB row **after** files are written; on failure, delete orphan files. Draft (unsaved) items go to a `tmp/` dir that's cleared on flow cancel and app start.

## 3. Image pipeline (Add item, steps 2–3 of the flow)

### 3.1 Preprocess
Downscale to **512px long edge** (model input), keep original file untouched.

### 3.2 Segmentation (the hard milestone)
- Model: **U2Net-lite (or U²-Net) converted to TFLite float32**, ~4–5MB, in `assets/models/`. Decide at Phase 1 start: convert once on PC with Python from open-source checkpoints, or use an existing pre-converted clothing/person segmentation model. One-time job, document the chosen source in `docs/` when picked.
- Input: 320×320 RGB, normalized to [0,1]. Output: 320×320 grayscale saliency map.
- Post-process: threshold mask at 0.5 → morphological cleanup (erode/dilate 1px) → upscale mask to image size with bilinear → **feather** edges (2px gaussian) → alpha = mask × 255 → composite RGBA cutout PNG.

### 3.3 Fallback
If inference throws or confidence mask is nearly empty/all-full → keep the original photo as the item image, no cutout, toast per `userFlow.md`. Never block saving an item on ML failure.

### 3.4 Eraser brush (cutout review)
Simple overlay: user strokes erase alpha to 0 (soft round stamp, radius ~20px at display scale, mapped to image coords). Undo = keep a stack of previous alpha buffers (last 5). No re-running the model.

### 3.5 Caching
Model and interpreter load **once** at app start (lazy on first use is fine); reuse across items. Target < 3s per item on a mid-range phone.

## 4. Color extraction

1. Collect opaque pixels (alpha > 200) from the cutout, downsampled to ≤ 10k samples.
2. k-means, k=3, 8 iterations, in RGB space.
3. **Primary** = the cluster with most pixels; **secondary** = the next cluster whose centroid is ≥ ΔE 40 (CIELAB distance) from primary — otherwise no secondary (plain item).
4. Snap primary hex to a named-color list (~30 curated fashion names: navy, charcoal, cream, burgundy, olive…) = nearest by CIELAB; store both hex + name.
5. Colors are user-editable on the Details screen (picker = named-color grid, not a free color wheel — keeps the suggestion vocabulary closed).

## 5. Suggestion engine

Deterministic, rule-based, fully offline. Runs over the whole wardrobe in < 50ms for a few hundred items.

### 5.1 Candidate generation
- Base: `dress + shoes` **or** `top + bottom + shoes`.
- `outerwear` and `accessory` are added to a candidate only if tagged with a compatible season; each is optional and scored separately (best-matching one wins).
- Season gate: candidate's items must not mix `summer`-only with `winter`-only; `all` matches anything.

### 5.2 Harmony scoring (primary colors, in HSL space)
For each pair among the candidate's primaries, score the best matching rule:
| Rule | Condition (hue distance d°) | Score |
|---|---|---|
| Monochrome | d < 20 | 6 |
| Analogous | 20 ≤ d < 50 | 7 |
| Complementary | 150 ≤ d ≤ 210 | 9 |
| Split-complementary / triadic | 100–150 or 210–260 | 7 |
| Neutral + accent | either color S < 0.18 | 8 |
| Else | — | 2 (clash) |

Sum over pairs, then apply penalties:
- **Two loud primaries** (both S > 0.55 and both V > 0.55, neither neutral): −4.
- **3+ chromatic colors** (S ≥ 0.18) in one outfit: −3 each beyond two.
- **Season mismatch**: filtered out earlier; `accessory` mismatch: −2.

### 5.3 Book palette bonus
**Done (2026-11-09):** `assets/data/palettes.json` now contains all **348 combinations** from *A Dictionary of Color Combinations* Vol. 1, sourced from the espectro.dev API (raw data + provenance in `docs/data/`). Format: `{"palettes": [{"name": "wada-001", "colors": ["#D96629", …]}, …]}`. If a candidate's primaries both appear (±ΔE 25) within one palette group: **+5** and the reason names the pairing (`wada-<id>`).

### 5.4 Reasons
Each rule hit generates the one-liner shown on the card ("Navy + mustard — complementary accents"; "Cream + olive — quiet base, one accent"). Rank candidates, dedupe near-identical combos (same slot items), return top 3. Shuffle = next 3 by rank, with shown combos deprioritized until the pool resets.

### 5.5 Live harmony readout (outfit builder)
Same scorer, bucketed: score ≥ 18 → "Harmonious", 12–17 → "Mixed", < 12 → "Clashing".

## 6. Backup / restore

- Export: `archive` → zip { `closet.db`, `images/**` } → `share_plus` (Drive/PC).
- Restore: pick zip → validate (db opens, schema version matches or migrates) → confirm dialog with item count → swap dirs transactionally (import to `tmp`, then rename over live, keep the old dir until success).

## 7. Error handling policy

- **ML failures never lose user data** (§3.3).
- DB writes are small and transactional; drift migrations are versioned from schema v1 — never edit an applied migration, always add a new one.
- Any unhandled async error → global zone handler → log to console + non-blocking snackbar; the app never white-screens.

## 8. Test strategy

- Unit: harmony scorer (table-driven: known pairs → expected rule+score), color extraction (synthetic images with known dominant colors), DB invariants (dress/top-bottom exclusivity, cascade delete).
- Manual on phone: the Flow 2 loop with 10 real garments; measure segmentation time.
- The scorer gets a **spreadsheet prototype first** (plan requirement) — validate the rules feel right before they become code.

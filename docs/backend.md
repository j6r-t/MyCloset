# MyCloset â€” Local Logic (backend.md)

There is **no server**. "Backend" here means everything that runs inside the app: storage, the image pipeline, color extraction, and the suggestion engine. Each feature is specified end-to-end so implementation is mechanical.

## 1. Stack & packages (keep minimal)

| Concern | Choice | Package |
|---|---|---|
| Framework | Flutter (Android-only target) | â€” |
| DB | SQLite via drift (typed, migrations) | `drift`, `drift_flutter` |
| Photo capture / pick | `image_picker` | |
| ML inference | TFLite segmentation | `tflite_flutter` |
| Image decode/resize/pixels | `image` (pure Dart) |
| Fonts | Cormorant Garamond + Inter | `google_fonts` |
| Icons | Material Symbols Outlined | `material_symbols_icons` |
| Paths | app documents dir | `path_provider` |
| Backup zip | `archive` + `share_plus` |
| State | plain `StatefulWidget` + `ChangeNotifier` until it hurts â€” no Riverpod/Bloc for MVP |

## 2. Storage layer

### 2.1 Database (drift)

```sql
items (
  id INTEGER PK AUTOINCREMENT,
  name TEXT NOT NULL,                -- optional in UI; defaults to 'Piece #<id>'
  category TEXT NOT NULL CHECK (category IN ('top','bottom','dress','shoes','outerwear','accessory')),
  subtype TEXT,                -- 't-shirt', 'jeans', 'blazer'â€¦
  brand TEXT,
  price REAL,                  -- USD/EUR
  size TEXT,                   -- v2: 'XS'â€¦'XL', numeric, free text
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
  -- slot âˆˆ {dress, top, bottom, shoes, outerwear, accessory}
  -- invariant enforced in code: dress present âŸº top & bottom absent
```

Indexes: `items(category)`, `items(season)`. Delete item â†’ delete its `outfit_items` rows (outfit keeps the slot empty; see `userFlow.md` edge behaviors).

**Migration v1â†’v2 (2026-11-10):** `ALTER TABLE items ADD COLUMN size TEXT` and `ADD COLUMN layer_type TEXT` (+ CHECK enforced at app level since SQLite can't add CHECK via ALTER). Engine rule added: a `top` with `layer_type` `outer` or `both` may also fill the outerwear slot in candidate generation.

### 2.2 File layout

```
<documents>/images/{item_id}/original.jpg    -- max 1600px long edge, JPEG q85
<documents>/images/{item_id}/cutout.png
<documents>/backups/closet_backup_<date>.zip
```

Save DB row **after** files are written; on failure, delete orphan files. Draft (unsaved) items go to a `tmp/` dir that's cleared on flow cancel and app start.

## 3. Image pipeline (Add item, steps 2â€“3 of the flow)

### 3.1 Preprocess
Downscale to **512px long edge** (model input), keep original file untouched.

### 3.2 Segmentation (the hard milestone)
- **Model chosen (2026-11-10): `assets/models/u2netp_320.tflite`** (2.4MB) â€” UÂ²-Netp float16 conversion, verified by flatbuffer inspection. Provenance: Hwang2212/flutter_tflite_imagebackground_remove (GitHub raw); authenticity corroborated by its 7-output structure (authentic UÂ²-Net signature). Fallback quality option (never downloaded into app): official Google LiteRT full UÂ²-Net fp16, 88MB, https://huggingface.co/litert-community/U-2-Net (Apache-2.0).
- **Verified tensor contract:** input `[1,320,320,3]` float32 NHWC; outputs **7** maps, each `[1,320,320,1]` float32 â€” take **output index 0** (the final fused d0 saliency map).
- **Preprocessing:** resize to 320Ã—320 RGB; normalize per the official UÂ²-Net recipe (divide pixels by the image's max value). Alternative to try if masks look off: ImageNet mean/std normalization.
- Inference: run via `tflite_flutter` **inside an isolate** (target < 3s on a mid-range phone); interpreter loaded once and reused.
- Post-process: threshold mask at 0.5 â†’ morphological cleanup (erode/dilate 1px) â†’ upscale mask to image size with bilinear â†’ **feather** edges (2px gaussian) â†’ alpha = mask Ã— 255 â†’ composite RGBA cutout PNG.

### 3.3 Fallback
If inference throws or confidence mask is nearly empty/all-full â†’ keep the original photo as the item image, no cutout, toast per `userFlow.md`. Never block saving an item on ML failure.

### 3.4 Eraser brush (cutout review)
Simple overlay: user strokes erase alpha to 0 (soft round stamp, radius ~20px at display scale, mapped to image coords). Undo = keep a stack of previous alpha buffers (last 5). No re-running the model.

### 3.5 Caching
Model and interpreter load **once** at app start (lazy on first use is fine); reuse across items. Target < 3s per item on a mid-range phone.

## 4. Color extraction

1. Collect opaque pixels (alpha > 200) from the cutout, downsampled to â‰¤ 10k samples; edge erosion drops pixels within 2px of a transparent pixel (segmentation-halo defense; falls back to all opaque samples when fewer than 500 interior pixels remain, so thin straps keep their color).
2. k-means, k=5, 8 iterations, distance in CIELAB space. Clusters within Î”E 15 of a larger cluster merge (shadow/highlight fragments of one garment color fold together).
3. **Primary** = the merged cluster with most pixels; **secondary** = the next merged cluster whose centroid is â‰¥ Î”E 25 from primary, with a two-tier rule: Î”E â‰¥ 40 is always distinct; 25â€“40 is distinct only when the difference is not pure lighting (neutral vs chromatic always counts; two chromatics need a hue gap â‰¥ 20Â°; two neutrals need a lightness gap â‰¥ 25). Candidates under 5% sample share are skipped. Otherwise no secondary (plain item).
4. Snap primary hex to a named-color list (36 curated fashion names: navy, charcoal, cream, burgundy, oliveâ€¦) = nearest by CIELAB (chroma-weighted 1.5Ã—; near-neutral centroids snap among neutrals only); store both hex + name.
5. Colors are user-editable on the Details screen (continuous HSV radial wheel â€” hue around the circle, white center to saturated rim â€” whose picked hue/saturation snaps to the same closed named-color vocabulary, keeping the suggestion engine's terms fixed).

## 5. Suggestion engine

Deterministic, rule-based, fully offline. Runs over the whole wardrobe in < 50ms for a few hundred items.

### 5.1 Candidate generation
- Base: `dress + shoes` **or** `top + bottom + shoes`.
- `outerwear` and `accessory` are added to a candidate only if tagged with a compatible season; each is optional and scored separately (best-matching one wins).
- Season gate: candidate's items must not mix `summer`-only with `winter`-only; `all` matches anything.

### 5.2 Harmony scoring (primary colors, in HSL space)
For each pair among the candidate's primaries, score the best matching rule:
| Rule | Condition (hue distance dÂ°) | Score |
|---|---|---|
| Monochrome | d < 20 | 6 |
| Analogous | 20 â‰¤ d < 50 | 7 |
| Complementary | 150 â‰¤ d â‰¤ 210 | 9 |
| Split-complementary / triadic | 100â€“150 or 210â€“260 | 7 |
| Neutral + accent | either color S < 0.18 | 8 |
| Else | â€” | 2 (clash) |

Sum over pairs, then apply penalties:
- **Two loud primaries** (both S > 0.55 and both V > 0.55, neither neutral): âˆ’4.
- **3+ chromatic colors** (S â‰¥ 0.18) in one outfit: âˆ’3 each beyond two.
- **Season mismatch**: filtered out earlier; `accessory` mismatch: âˆ’2.

### 5.3 Book palette bonus
**Done (2026-11-09):** `assets/data/palettes.json` now contains all **348 combinations** from *A Dictionary of Color Combinations* Vol. 1, sourced from the espectro.dev API (raw data + provenance in `docs/data/`). Format: `{"palettes": [{"name": "wada-001", "colors": ["#D96629", â€¦]}, â€¦]}`. If a candidate's primaries both appear (Â±Î”E 25) within one palette group: **+5** and the reason names the pairing (`wada-<id>`).

### 5.4 Reasons
Each rule hit generates the one-liner shown on the card ("Navy + mustard â€” complementary accents"; "Cream + olive â€” quiet base, one accent"). Rank candidates, dedupe near-identical combos (same slot items), return top 3. Shuffle = next 3 by rank, with shown combos deprioritized until the pool resets.

### 5.5 Live harmony readout (outfit builder)
Same scorer, bucketed: score â‰¥ 18 â†’ "Harmonious", 12â€“17 â†’ "Mixed", < 12 â†’ "Clashing".

## 5b. Online identification (Tier 2, added 2026-11-10) â€” the ONLY networked feature

Opt-in, silent auto-fill (Fitted-style): adding a new item auto-runs identification in the background; suggested brand/type/price fill **only empty fields** (brief "auto" chip on each filled row). Edit mode never auto-runs. No manual button.

- **Pipeline cascade** (`identification_pipeline.dart`): SerpAPI Lens (Image API upload â†’ image_id â†’ google_lens â€” lens is URL/image_id-only per live docs, hence two-step) â†’ shopping text-mode salvage from on-device hints â†’ Cloud Vision WEB_DETECTION (inline base64 cutout, 512px JPEG) â†’ graceful unavailable with per-step reasons. 15s timeouts, URL dedupe, never throws.
- **Keys**: SerpAPI + Cloud Vision keys stored by the user in Settings â†’ app_settings table (schema v3); masked UI, "Set"/"Not set" only; never hardcoded, logged, or committed.
- **Offline guarantee**: INTERNET permission serves this feature alone; no HTTP call may start except from the auto-fill on the add-item form.
- **Quota reality**: SerpAPI Lens â‰ˆ2 credits/item (~50 items/mo free) then falls to Vision (1,000/mo free).

## 6. Backup / restore

- Export: `archive` â†’ zip { `closet.db`, `images/**` } â†’ `share_plus` (Drive/PC).
- Restore: pick zip â†’ validate (db opens, schema version matches or migrates) â†’ confirm dialog with item count â†’ swap dirs transactionally (import to `tmp`, then rename over live, keep the old dir until success).

## 7. Error handling policy

- **ML failures never lose user data** (Â§3.3).
- DB writes are small and transactional; drift migrations are versioned from schema v1 â€” never edit an applied migration, always add a new one.
- Any unhandled async error â†’ global zone handler â†’ log to console + non-blocking snackbar; the app never white-screens.

## 8. Test strategy

- Unit: harmony scorer (table-driven: known pairs â†’ expected rule+score), color extraction (synthetic images with known dominant colors), DB invariants (dress/top-bottom exclusivity, cascade delete).
- Manual on phone: the Flow 2 loop with 10 real garments; measure segmentation time.
- The scorer gets a **spreadsheet prototype first** (plan requirement) â€” validate the rules feel right before they become code.

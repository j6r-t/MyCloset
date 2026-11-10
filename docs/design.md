# MyCloset — Design System (design.md) — v2 "Fitted-minimal"

**Direction: white/gray/black minimalism** inspired by the Fitted app (reference screenshots in `fitted_reference/`). The interface nearly disappears: white background, cutouts floating plain (no card frames, no grid labels), black pill buttons as the only strong ink, green reserved for money. Replaces the v1 editorial/cream/serif identity entirely.

**Mode: Operate.** **Icon policy (hard rule):** no emojis anywhere — Material Symbols (Outlined) only.

**Rejected from the reference (do not build):** gamification/quests/Fitcoin/streaks, "Enhance", "Try on Piece"/virtual try-on, Community/Shop/Stylist tabs, marketplace/selling.

---

## 1. Color (light theme primary; dark theme added 2026-11-10)

| Token | Value | Use |
|---|---|---|
| `bg` | `#FFFFFF` | App background |
| `surface` | `#FFFFFF` | Cards, sheets |
| `tile` | `#F5F5F6` | Item-detail hero card; eraser canvas backdrop; grid tiles only as a whisper (`#F9F9FA`) |
| `ink` | `#0B0B0C` | Primary text, black pill fills |
| `ink-secondary` | `#8A8A8E` | Labels, inactive nav, captions |
| `hairline` | `#ECECED` | 1px dividers, outlined-pill borders |
| `money` | `#1E9E4B` | Price/value figures only |
| `danger` | `#C4362C` | Destructive actions |
| `category` | Pants `#F06292` · Tops `#64A8F0` · Shoes `#F2C94C` · Dress `#9B7BD1` · Outerwear `#4DB6AC` · Accessory `#F2994A` | Dashboard category bars only — never UI chrome |

### Dark theme (Settings: System / Light / Dark; persisted via app_settings table, schema v3)

Warm near-black surfaces (`bg #131211`, `surface #1F1D1B`), warm-white ink (`#F4F2EF`), darkened hairlines, lifted `money #4CC97A` / `danger #E57368`, category colors one step lighter. **Primary pairing inverts on dark: white pill fill, ink content.** All screens must use `AppColors.of(context)` — no hardcoded light colors.

Rules: black pills (`ink` fill, white text) are the primary action style; outlined pills (hairline border, ink text) are secondary; no other fills. Never tint anything behind a garment cutout except `tile`.

## 2. Typography

**System sans only** (default platform font; no google_fonts). One voice, weight does the hierarchy:

| Role | Spec |
|---|---|
| Value headline (dashboard) | 40 / semibold |
| Screen titles | 22 / semibold |
| Section/tab labels | 16 / medium (active) · 16 / regular `ink-secondary` (inactive) |
| Metadata values | 16 / regular `ink` |
| Metadata labels | 15 / regular `ink-secondary` |
| Buttons/pills | 15 / medium |
| Captions | 13 / regular `ink-secondary` |

No serif anywhere. No letterspaced small caps (v1 artifact — removed).

## 3. Shape, spacing, elevation

- Radii: pills 24 (full), hero/flat-lay cards 16, nav pill 28, sheets 20.
- Spacing: 4pt grid; screen gutter 16; grid gap 2 (Fitted's grid is nearly seamless); section rhythm 24–32.
- Elevation: none. The floating bottom nav gets one soft shadow (y=4, blur=20, black @ 12%). Everything else flat.

## 4. Iconography

Material Symbols Outlined, 22–24px, `ink-secondary`; active tab `ink`. Nav set: `checkroom` (Wardrobe), `hanger`→`dry_cleaning` fallback (Outfits), `auto_awesome` (Suggest), `settings` (Settings). Plus `add`, `close`, `edit` (pencil), `delete_outline`, `arrow_back`, `tune`, `camera_alt`, `photo_library`, `brush`, `shuffle`, `check`.

## 5. Navigation structure (replaces v1 hub-and-push)

**Floating bottom pill nav + black + FAB** (Fitted pattern): a rounded white pill (hairline border) with 4 tabs — **Wardrobe · Outfits · Suggest · Settings** (icon above 13px label; active = `ink`, inactive = `ink-secondary`) — docked bottom-center; a separate black circular **+** FAB (56px) to its right that starts the add-item flow from anywhere.

## 6. Screens

1. **Wardrobe (home dashboard)** — top: total wardrobe value as the headline ("1 240 TND", 40/semibold, centered); below it the **category bar chart**: one rounded block per category with items, height ∝ count, colored per `category` tokens, value caption above each block, category label below. Then tab-style section switch is NOT used (bottom nav owns tabs). Then sticky **filter pills** (Category · Type · Color · Season, outlined pills with chevron-down, multi-select sheets). Then the 3-column **seamless grid**: cutouts floating plain, no labels, no card borders, tile barely distinguishable from bg; **first tile = "+ Add Piece"** (ink + icon centered, hairline-dashed square). Long-press a tile → action sheet (Edit / Delete). Tap → item detail.
2. **Capture** — unchanged flow, restyled: black pill "Take photo", outlined pill "Choose from gallery", caption "Plain background works best".
3. **Cutout review** — cutout large on `tile` rounded card (no frame around it), Eraser (icon pill) toggle, Retake outlined pill, Continue black pill. Stub-mode note stays (quiet caption).
4. **Details form** — fields in Fitted's order, hairline rows with per-row edit: Value (TND, `money` green) · Brand · Type (subtype) · Garment Type (category) · Size (text: XS–XL / numeric) · Layer Type (Inner / Outer / Both pill-selector, shown only for top & outerwear) · Color (named, swatch dot + name) · Season · Fabric · Notes. Name optional — defaults to "Piece #<id>".
5. **Item detail** — hero cutout on `tile` card; action pills row: **"Create fit"** (black — opens outfit builder pre-seeded with this item) · Edit · Delete (outlined); then the same hairline metadata rows as the form, per-row pencil edits; delete confirms via sheet.
6. **Outfits** — 2-column grid; first tile **"Create Fit"** (+ icon, dashed). Each outfit renders as a **vertical flat-lay column**: every garment its own cutout stacked top→bottom (top, bottom, shoes; outerwear/accessory appended), small 6px gaps, **never overlapping**, no card frame — on `bg`; name caption + date below the column.
7. **Outfit builder** — live vertical flat-lay preview (same rendering as #6) + slot chips beneath (Dress OR Top+Bottom, Shoes, Outerwear, Accessory — tap chip → picker); harmony readout as a caption word ("Harmonious / Mixed / Clashing"); Save = black pill.
8. **Suggestions** — top-3 as vertical flat-lay columns (same renderer), each with its reason caption ("Navy + mustard — complementary accents"); Shuffle icon regenerates; one-tap save.
9. **Settings** — plain hairline list: Theme (System/Light/Dark pills), Export backup, Restore, About. Minimal.

### Component: NamedColorWheel (added 2026-11-10)

Radial picker for the closed 36-color vocabulary, used from the details form: 28 chromatic colors as 44px swatches on a hue-ordered outer ring; 8 neutrals clustered on an inner ring around a 48px center disc showing the current selection. Press-drag summons an **offset color loupe** 80px above the finger (clamped to the wheel): 72px enlarged swatch + name caption, theme-aware hairline border + soft shadow; hovered swatch gets an ink ring; haptic tick per hover change; release commits, plain tap selects, cancel dismisses without committing. The sheet's drag-to-dismiss is disabled while the wheel is active.

## 7. Motion (quiet, unchanged policy)

150–250ms, `easeOutCubic`; fade+8px slide for pushes; shimmer placeholder while processing; new-tile highlight = 1s accent border fade. No springs/bounce/confetti.

## 8. Do / Don't

- **Do** keep cutouts frameless — if a container is unavoidable (detail hero), it's `tile` with radius 16 and nothing else.
- **Don't** put text labels under grid items — imagery only.
- **Don't** overlap garments in outfit renders — vertical column, always.
- **Don't** use colored chrome behind clothes; `category` colors live only in the dashboard chart.
- **Don't** use serif fonts, cream tones, or gold (v1 artifacts).
- Empty states: centered ink statement + one outlined pill action, no illustration.

## Migration notes from v1

`lib/ui/theme.dart` drops google_fonts + dark theme + cream/gold tokens. All screens restyle per §6; navigation rebuilds to bottom-pill + FAB (Wardrobe/Outfits/Suggest/Settings become tab roots — state preserved per tab).

# MyCloset â€” Design System (design.md) â€” v2 "Fitted-minimal"

**Direction: white/gray/black minimalism** inspired by the Fitted app (reference screenshots in `fitted_reference/`). The interface nearly disappears: white background, cutouts floating plain (no card frames, no grid labels), black pill buttons as the only strong ink, green reserved for money. Replaces the v1 editorial/cream/serif identity entirely.

**Mode: Operate.** **Icon policy (hard rule):** no emojis anywhere â€” Material Symbols (Outlined) only.

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
| `category` | Pants `#F06292` Â· Tops `#64A8F0` Â· Shoes `#F2C94C` Â· Dress `#9B7BD1` Â· Outerwear `#4DB6AC` Â· Accessory `#F2994A` | Dashboard category bars only â€” never UI chrome |

### Dark theme (Settings: System / Light / Dark; persisted via app_settings table, schema v3)

Warm near-black surfaces (`bg #131211`, `surface #1F1D1B`), warm-white ink (`#F4F2EF`), darkened hairlines, lifted `money #4CC97A` / `danger #E57368`, category colors one step lighter. **Primary pairing inverts on dark: white pill fill, ink content.** All screens must use `AppColors.of(context)` â€” no hardcoded light colors.

Rules: black pills (`ink` fill, white text) are the primary action style; outlined pills (hairline border, ink text) are secondary; no other fills. Never tint anything behind a garment cutout except `tile`.

## 2. Typography

**System sans only** (default platform font; no google_fonts). One voice, weight does the hierarchy:

| Role | Spec |
|---|---|
| Value headline (dashboard) | 40 / semibold |
| Screen titles | 22 / semibold |
| Section/tab labels | 16 / medium (active) Â· 16 / regular `ink-secondary` (inactive) |
| Metadata values | 16 / regular `ink` |
| Metadata labels | 15 / regular `ink-secondary` |
| Buttons/pills | 15 / medium |
| Captions | 13 / regular `ink-secondary` |

No serif anywhere. No letterspaced small caps (v1 artifact â€” removed).

## 3. Shape, spacing, elevation

- Radii: pills 24 (full), hero/flat-lay cards 16, nav pill 28, sheets 20.
- Spacing: 4pt grid; screen gutter 16; grid gap 2 (Fitted's grid is nearly seamless); section rhythm 24â€“32.
- Elevation: none. The floating bottom nav gets one soft shadow (y=4, blur=20, black @ 12%). Everything else flat.

## 4. Iconography

Material Symbols Outlined, 22â€“24px, `ink-secondary`; active tab `ink`. Nav set: `checkroom` (Wardrobe), `hanger`â†’`dry_cleaning` fallback (Outfits), `auto_awesome` (Suggest), `settings` (Settings). Plus `add`, `close`, `edit` (pencil), `delete_outline`, `arrow_back`, `tune`, `camera_alt`, `photo_library`, `brush`, `shuffle`, `check`.

## 5. Navigation structure (replaces v1 hub-and-push)

**Floating bottom pill nav + black + FAB** (Fitted pattern): a rounded white pill (hairline border) with 4 tabs â€” **Wardrobe Â· Outfits Â· Suggest Â· Settings** (icon above 13px label; active = `ink`, inactive = `ink-secondary`) â€” docked bottom-center; a separate black circular **+** FAB (56px) to its right that starts the add-item flow from anywhere.

## 6. Screens

1. **Wardrobe (home dashboard)** â€” top: total wardrobe value as the headline ("1 240 USD/EUR", 40/semibold, centered); below it the **category bar chart**: one rounded block per category with items, height âˆ count, colored per `category` tokens, value caption above each block, category label below. Then tab-style section switch is NOT used (bottom nav owns tabs). Then sticky **filter pills** (Category Â· Type Â· Color Â· Season, outlined pills with chevron-down, multi-select sheets). Then the 3-column **seamless grid**: cutouts floating plain, no labels, no card borders, tile barely distinguishable from bg; **first tile = "+ Add Piece"** (ink + icon centered, hairline-dashed square). Long-press a tile â†’ action sheet (Edit / Delete). Tap â†’ item detail.
2. **Capture** â€” unchanged flow, restyled: black pill "Take photo", outlined pill "Choose from gallery", caption "Plain background works best".
3. **Cutout review** â€” cutout large on `tile` rounded card (no frame around it), Eraser (icon pill) toggle, Retake outlined pill, Continue black pill. Stub-mode note stays (quiet caption).
4. **Details form** â€” fields in Fitted's order, hairline rows with per-row edit: Value (USD/EUR, `money` green) Â· Brand Â· Type (subtype) Â· Garment Type (category) Â· Size (text: XSâ€“XL / numeric) Â· Layer Type (Inner / Outer / Both pill-selector, shown only for top & outerwear) Â· Color (named, swatch dot + name) Â· Season Â· Fabric Â· Notes. Name optional â€” defaults to "Piece #<id>".
5. **Item detail** â€” hero cutout on `tile` card; action pills row: **"Create fit"** (black â€” opens outfit builder pre-seeded with this item) Â· Edit Â· Delete (outlined); then the same hairline metadata rows as the form, per-row pencil edits; delete confirms via sheet.
6. **Outfits** â€” 2-column grid; first tile **"Create Fit"** (+ icon, dashed). Each outfit renders as a **vertical flat-lay column**: every garment its own cutout stacked topâ†’bottom (top, bottom, shoes; outerwear/accessory appended), small 6px gaps, **never overlapping**, no card frame â€” on `bg`; name caption + date below the column.
7. **Outfit builder** â€” live vertical flat-lay preview (same rendering as #6) + slot chips beneath (Dress OR Top+Bottom, Shoes, Outerwear, Accessory â€” tap chip â†’ picker); harmony readout as a caption word ("Harmonious / Mixed / Clashing"); Save = black pill.
8. **Suggestions** â€” top-3 as vertical flat-lay columns (same renderer), each with its reason caption ("Navy + mustard â€” complementary accents"); Shuffle icon regenerates; one-tap save.
9. **Settings** â€” plain hairline list: Theme (System/Light/Dark pills), Export backup, Restore, About. Minimal.

### Component: NamedColorWheel (added 2026-11-10)

Radial picker for the closed 36-color vocabulary, used from the details form: 28 chromatic colors as 44px swatches on a hue-ordered outer ring; 8 neutrals clustered on an inner ring around a 48px center disc showing the current selection. Press-drag summons an **offset color loupe** 80px above the finger (clamped to the wheel): 72px enlarged swatch + name caption, theme-aware hairline border + soft shadow; hovered swatch gets an ink ring; haptic tick per hover change; release commits, plain tap selects, cancel dismisses without committing. The sheet's drag-to-dismiss is disabled while the wheel is active.

## 7. Motion (quiet, unchanged policy)

150â€“250ms, `easeOutCubic`; fade+8px slide for pushes; shimmer placeholder while processing; new-tile highlight = 1s accent border fade. No springs/bounce/confetti.

## 8. Do / Don't

- **Do** keep cutouts frameless â€” if a container is unavoidable (detail hero), it's `tile` with radius 16 and nothing else.
- **Don't** put text labels under grid items â€” imagery only.
- **Don't** overlap garments in outfit renders â€” vertical column, always.
- **Don't** use colored chrome behind clothes; `category` colors live only in the dashboard chart.
- **Don't** use serif fonts, cream tones, or gold (v1 artifacts).
- Empty states: centered ink statement + one outlined pill action, no illustration.

## Migration notes from v1

`lib/ui/theme.dart` drops google_fonts + dark theme + cream/gold tokens. All screens restyle per Â§6; navigation rebuilds to bottom-pill + FAB (Wardrobe/Outfits/Suggest/Settings become tab roots â€” state preserved per tab).

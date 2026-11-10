// Shared enums for MyCloset.
//
// Values double as the strings stored in the database (see
// `docs/backend.md` section 2.1), so they must never be renamed without a
// migration.

/// Wardrobe item category. Six fixed values chosen in the project handoff.
enum Category { top, bottom, dress, shoes, outerwear, accessory }

/// Season tag for an item. `all` matches anything.
enum Season { summer, winter, all }

/// Layering role of an item (schema v2, docs/backend.md 2.1).
///
/// Only meaningful for `top` and `outerwear` items; stored as null for every
/// other category (enforced in the save/update path of
/// `lib/database/app_database.dart`). A `top` with [outer] or [both] may
/// additionally fill an outfit's outerwear slot (backend.md 5.1).
enum LayerType { inner, outer, both }

/// Slot an item can occupy inside an outfit.
///
/// Invariant enforced in `lib/database/app_database.dart`: an outfit contains
/// a `dress` if and only if it contains neither `top` nor `bottom`.
enum OutfitSlot { dress, top, bottom, shoes, outerwear, accessory }

/// Parses a category stored in the database. Throws on unknown values.
Category categoryFromDb(String value) {
  for (final c in Category.values) {
    if (c.name == value) return c;
  }
  throw ArgumentError.value(value, 'value', 'Unknown category');
}

/// Parses a season stored in the database. Throws on unknown values.
Season seasonFromDb(String value) {
  for (final s in Season.values) {
    if (s.name == value) return s;
  }
  throw ArgumentError.value(value, 'value', 'Unknown season');
}

/// Parses a layer type stored in the database. Null stays null (the column
/// is nullable and null is the default for non-layering items); unknown
/// values throw.
LayerType? layerTypeFromDb(String? value) {
  if (value == null) return null;
  for (final l in LayerType.values) {
    if (l.name == value) return l;
  }
  throw ArgumentError.value(value, 'value', 'Unknown layer type');
}

/// Parses an outfit slot stored in the database. Throws on unknown values.
OutfitSlot outfitSlotFromDb(String value) {
  for (final s in OutfitSlot.values) {
    if (s.name == value) return s;
  }
  throw ArgumentError.value(value, 'value', 'Unknown outfit slot');
}

/// True for the slots that participate in the dress/top+bottom exclusivity.
bool slotIsDressOrTorso(OutfitSlot slot) =>
    slot == OutfitSlot.dress ||
    slot == OutfitSlot.top ||
    slot == OutfitSlot.bottom;

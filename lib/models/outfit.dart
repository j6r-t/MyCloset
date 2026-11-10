import 'enums.dart';

/// A saved outfit, mirroring the `outfits` table (docs/backend.md 2.1).
class Outfit {
  final int id;
  final String name;
  final DateTime createdAt;

  const Outfit({required this.id, required this.name, required this.createdAt});

  @override
  String toString() => 'Outfit($id, $name)';
}

/// One row of `outfit_items`: an [item] occupying a [slot] of an outfit.
///
/// Primary key is (outfitId, slot): at most one item per slot per outfit.
class OutfitEntry {
  final int outfitId;
  final int itemId;
  final OutfitSlot slot;

  const OutfitEntry({
    required this.outfitId,
    required this.itemId,
    required this.slot,
  });

  @override
  String toString() => 'OutfitEntry($outfitId, $itemId, ${slot.name})';
}

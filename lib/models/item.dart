import 'enums.dart';

/// A wardrobe item, mirroring the `items` table (docs/backend.md 2.1).
class Item {
  final int id;
  final String name;
  final Category category;

  /// Optional finer type, e.g. 't-shirt', 'jeans', 'blazer'.
  final String? subtype;
  final String? brand;

  /// Price in TND, nullable.
  final double? price;

  /// Free-text size label, e.g. 'M', '40', 'one size' (schema v2). Nullable.
  final String? size;

  /// Layering role, only set for top/outerwear items (schema v2). Null for
  /// every other category; see [LayerType] for the engine rule this drives.
  final LayerType? layerType;

  /// Item condition (schema v4, Fitted-inspired). Nullable - the user is
  /// never forced to grade a piece; see [Condition] for the fixed vocabulary.
  final Condition? condition;

  final Season season;
  final String? fabric;
  final String? notes;

  /// Primary color as '#RRGGBB'. Never null (schema NOT NULL).
  final String colorPrimaryHex;

  /// Curated color name for the primary color, e.g. 'navy'. Nullable.
  final String? colorPrimaryName;

  /// Secondary color (stripes/plaid) as '#RRGGBB', nullable.
  final String? colorSecondaryHex;
  final String? colorSecondaryName;

  /// Absolute path to the original photo (max 1600px long edge, JPEG q85).
  final String imagePath;

  /// Absolute path to the RGBA cutout PNG. When segmentation fell back to the
  /// original photo this equals [imagePath].
  final String cutoutPath;
  final DateTime createdAt;

  const Item({
    required this.id,
    required this.name,
    required this.category,
    this.subtype,
    this.brand,
    this.price,
    this.size,
    this.layerType,
    this.condition,
    this.season = Season.all,
    this.fabric,
    this.notes,
    required this.colorPrimaryHex,
    this.colorPrimaryName,
    this.colorSecondaryHex,
    this.colorSecondaryName,
    required this.imagePath,
    required this.cutoutPath,
    required this.createdAt,
  });

  Item copyWith({
    int? id,
    String? name,
    Category? category,
    String? subtype,
    String? brand,
    double? price,
    String? size,
    LayerType? layerType,
    Condition? condition,
    Season? season,
    String? fabric,
    String? notes,
    String? colorPrimaryHex,
    String? colorPrimaryName,
    String? colorSecondaryHex,
    String? colorSecondaryName,
    String? imagePath,
    String? cutoutPath,
    DateTime? createdAt,
  }) {
    return Item(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      subtype: subtype ?? this.subtype,
      brand: brand ?? this.brand,
      price: price ?? this.price,
      size: size ?? this.size,
      layerType: layerType ?? this.layerType,
      condition: condition ?? this.condition,
      season: season ?? this.season,
      fabric: fabric ?? this.fabric,
      notes: notes ?? this.notes,
      colorPrimaryHex: colorPrimaryHex ?? this.colorPrimaryHex,
      colorPrimaryName: colorPrimaryName ?? this.colorPrimaryName,
      colorSecondaryHex: colorSecondaryHex ?? this.colorSecondaryHex,
      colorSecondaryName: colorSecondaryName ?? this.colorSecondaryName,
      imagePath: imagePath ?? this.imagePath,
      cutoutPath: cutoutPath ?? this.cutoutPath,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() => 'Item($id, $name, ${category.name})';
}

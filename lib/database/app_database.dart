import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../models/outfit.dart';

// ---------------------------------------------------------------------------
// Schema (docs/backend.md 2.1)
//
// This project runs drift WITHOUT code generation (no build_runner), so the
// tables below serve as the executable schema documentation while the DDL
// statements in [schemaStatements] create the actual tables. The two must
// stay in sync; the CHECK constraints in the SQL mirror the enums in
// lib/models/enums.dart.
//
// Schema version history starts at 1. v2 (2026-11-10) added items.size and
// items.layer_type (docs/backend.md 2.1); SQLite cannot add a CHECK via
// ALTER TABLE, so migrated databases have the layer_type CHECK enforced at
// app level (see [_assertLayerTypeAllowed]) while fresh installs get it in
// the DDL directly. v3 (2026-11-10) added app_settings, a tiny key-value
// table for app-level preferences (theme mode) that must survive restarts.
// v4 (2026-11-10) added items.condition (Fitted-inspired fixed vocabulary,
// nullable); the same SQLite limitation applies, so migrated databases rely
// on the app-level vocabulary guard while fresh DDL carries the CHECK.
// Never edit an applied migration: append a new step to
// [AppDatabase.migration]'s onUpgrade instead.
// ---------------------------------------------------------------------------

/// `items` table definition (see [schemaStatements] for the DDL).
class ItemsTable extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get category => text()(); // CHECK: one of the 6 Category values
  TextColumn get subtype => text().nullable()();
  TextColumn get brand => text().nullable()();
  RealColumn get price => real().nullable()(); // TND
  TextColumn get size => text().nullable()(); // v2: free-text size label
  // v2: null except top/outerwear; CHECK mirrored in the v2 DDL and enforced
  // at app level on migrated databases.
  TextColumn get layerType => text().nullable()();
  // v4: nullable Fitted-inspired condition; CHECK mirrored in the v4 DDL and
  // enforced at app level on migrated databases.
  TextColumn get condition => text().nullable()();
  TextColumn get season => text().withDefault(const Constant('all'))();
  TextColumn get fabric => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get colorPrimaryHex => text()();
  TextColumn get colorPrimaryName => text().nullable()();
  TextColumn get colorSecondaryHex => text().nullable()();
  TextColumn get colorSecondaryName => text().nullable()();
  TextColumn get imagePath => text()();
  TextColumn get cutoutPath => text()();
  IntColumn get createdAt => integer()(); // epoch milliseconds
}

/// `outfits` table definition.
class OutfitsTable extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get createdAt => integer()(); // epoch milliseconds
}

/// `outfit_items` table definition. Primary key is (outfitId, slot).
class OutfitItemsTable extends Table {
  IntColumn get outfitId =>
      integer().references(OutfitsTable, #id)();
  IntColumn get itemId => integer().references(ItemsTable, #id)();
  TextColumn get slot => text()(); // CHECK: one of the 6 OutfitSlot values

  @override
  Set<Column> get primaryKey => {outfitId, slot};
}

/// `app_settings` table definition (schema v3): a tiny key-value store for
/// app-level preferences that are not wardrobe data (currently only the
/// theme mode). Primary key is [key].
class AppSettingsTable extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// The drift database for MyCloset.
///
/// Because no code generation is used, typed access goes through the query
/// methods below, which map raw rows to the plain model classes in
/// lib/models/. Open the app database with [AppDatabase.open]; tests inject
/// their own executor (e.g. an in-memory NativeDatabase).
class AppDatabase extends GeneratedDatabase {
  /// Opens the production database: `closet.sqlite` in the app documents
  /// directory (drift_flutter's default location; the backup service relies
  /// on this path).
  ///
  /// `tempDirectoryPath: () => null` tells drift_flutter to skip its global
  /// `sqlite3.tempDirectory = ...` assignment (see drift_flutter's
  /// DriftNativeOptions.tempDirectoryPath docs: returning null leaves the
  /// temp directory unchanged). That assignment touches the native data
  /// symbol `sqlite3_temp_directory`, which some SQLite builds on Android do
  /// not export (the crash surfaced as "Could not resolve native function
  /// `sqlite3_temp_directory`" when saving an API key). We do not need the
  /// redirection: the wardrobe DB is tiny, queries are small, and the largest
  /// temp-space consumer is the few-MB VACUUM INTO backups, which SQLite
  /// handles with its default temporary location.
  factory AppDatabase.open() => AppDatabase(
        driftDatabase(
          name: 'closet',
          native: const DriftNativeOptions(tempDirectoryPath: _noTempDirectory),
        ),
      );

  /// [DriftNativeOptions.tempDirectoryPath] that never redirects the SQLite
  /// temporary directory (top-level so the closure stays const-constructible
  /// and isolate-sendable).
  static Future<String?> _noTempDirectory() async => null;

  AppDatabase(super.executor);

  @override
  int get schemaVersion => 4;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          for (final statement in schemaStatements) {
            await customStatement(statement);
          }
        },
        onUpgrade: (m, from, to) async {
          // Add future versions as incremental steps below and raise
          // [schemaVersion]; never edit an existing step.
          if (from < 2) {
            // v1 -> v2 (docs/backend.md 2.1): the two new item columns.
            // SQLite cannot add a CHECK constraint with ALTER TABLE, so the
            // layer_type values are validated in [_assertLayerTypeAllowed]
            // on every write instead.
            await customStatement('ALTER TABLE items ADD COLUMN size TEXT');
            await customStatement(
              'ALTER TABLE items ADD COLUMN layer_type TEXT',
            );
          }
          if (from < 3) {
            // v2 -> v3: the app_settings key-value table (theme mode and
            // future app-level preferences). Pure append - no existing
            // table changes, so no data migration is needed.
            await customStatement(appSettingsDdl);
          }
          if (from < 4) {
            // v3 -> v4 (Fitted-inspired item condition). SQLite cannot add
            // a CHECK constraint with ALTER TABLE, so the fixed vocabulary
            // is validated in [_assertConditionAllowed] on every write
            // instead.
            await customStatement('ALTER TABLE items ADD COLUMN condition TEXT');
          }
        },
        beforeOpen: (details) async {
          // Enforce the FK cascade declared in the DDL (item deletion
          // removes its outfit_items rows; outfit deletion removes all its
          // slot rows).
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// DDL for the app_settings table (schema v3). Shared by the fresh-install
  /// DDL list and the v2 -> v3 migration step.
  static const String appSettingsDdl = '''
    CREATE TABLE IF NOT EXISTS app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''';

  /// DDL for schema version 4 (fresh installs). Unlike the ALTER-based
  /// migration path this can carry the layer_type and condition CHECK
  /// constraints.
  static const List<String> schemaStatements = [
    '''
    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      category TEXT NOT NULL CHECK (category IN ('top','bottom','dress','shoes','outerwear','accessory')),
      subtype TEXT,
      brand TEXT,
      price REAL,
      size TEXT,
      layer_type TEXT CHECK (layer_type IN ('inner','outer','both')),
      condition TEXT CHECK (condition IN ('new_with_tags','new_without_tags','like_new','good','worn')),
      season TEXT NOT NULL DEFAULT 'all' CHECK (season IN ('summer','winter','all')),
      fabric TEXT,
      notes TEXT,
      color_primary_hex TEXT NOT NULL,
      color_primary_name TEXT,
      color_secondary_hex TEXT,
      color_secondary_name TEXT,
      image_path TEXT NOT NULL,
      cutout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_items_category ON items(category)',
    'CREATE INDEX IF NOT EXISTS idx_items_season ON items(season)',
    '''
    CREATE TABLE IF NOT EXISTS outfits (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS outfit_items (
      outfit_id INTEGER NOT NULL REFERENCES outfits(id) ON DELETE CASCADE,
      item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
      slot TEXT NOT NULL CHECK (slot IN ('dress','top','bottom','shoes','outerwear','accessory')),
      PRIMARY KEY (outfit_id, slot)
    )
    ''',
    // v3: app-level preferences key-value store (theme mode).
    appSettingsDdl,
  ];

  /// DDL for schema version 1, exactly as it shipped. Nothing at runtime
  /// executes this; it exists so the migration test can build a genuine v1
  /// database file and verify the v1 -> v2 upgrade against it. Kept in sync
  /// with the [schemaStatements] tables minus the v2 columns.
  static const List<String> schemaV1Statements = [
    '''
    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      category TEXT NOT NULL CHECK (category IN ('top','bottom','dress','shoes','outerwear','accessory')),
      subtype TEXT,
      brand TEXT,
      price REAL,
      season TEXT NOT NULL DEFAULT 'all' CHECK (season IN ('summer','winter','all')),
      fabric TEXT,
      notes TEXT,
      color_primary_hex TEXT NOT NULL,
      color_primary_name TEXT,
      color_secondary_hex TEXT,
      color_secondary_name TEXT,
      image_path TEXT NOT NULL,
      cutout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_items_category ON items(category)',
    'CREATE INDEX IF NOT EXISTS idx_items_season ON items(season)',
    '''
    CREATE TABLE IF NOT EXISTS outfits (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS outfit_items (
      outfit_id INTEGER NOT NULL REFERENCES outfits(id) ON DELETE CASCADE,
      item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
      slot TEXT NOT NULL CHECK (slot IN ('dress','top','bottom','shoes','outerwear','accessory')),
      PRIMARY KEY (outfit_id, slot)
    )
    ''',
  ];

  // ------------------------------------------------------------------ items

  /// Throws when [layerType] is set on a category that cannot layer
  /// (docs/backend.md 2.1: layer_type is null except for top/outerwear).
  /// This is the app-level CHECK that replaces the DDL constraint on
  /// databases migrated from schema v1, where ALTER TABLE cannot add a
  /// CHECK; fresh installs have both.
  static void _assertLayerTypeAllowed(Category category, LayerType? layerType) {
    final layers = category == Category.top || category == Category.outerwear;
    if (layerType != null && !layers) {
      throw ArgumentError.value(
        layerType,
        'layerType',
        'layer_type is only valid for top and outerwear items, '
            'not ${category.name}',
      );
    }
  }

  /// Throws when [condition] carries a value outside the fixed v4 vocabulary
  /// (docs/backend.md 2.1). The type system already guarantees this for the
  /// typed write path; the guard exists for the same reason as
  /// [_assertLayerTypeAllowed]: databases migrated from schema v3 have no
  /// DDL CHECK on the column, so this is the only line of defense.
  static void _assertConditionAllowed(Condition? condition) {
    if (condition != null &&
        !Condition.values.any((c) => c.dbValue == condition.dbValue)) {
      throw ArgumentError.value(
        condition,
        'condition',
        'condition must use the fixed schema v4 vocabulary',
      );
    }
  }

  /// Inserts an item row and returns its generated id.
  Future<int> insertItem({
    required String name,
    required Category category,
    String? subtype,
    String? brand,
    double? price,
    String? size,
    LayerType? layerType,
    Condition? condition,
    Season season = Season.all,
    String? fabric,
    String? notes,
    required String colorPrimaryHex,
    String? colorPrimaryName,
    String? colorSecondaryHex,
    String? colorSecondaryName,
    required String imagePath,
    required String cutoutPath,
    DateTime? createdAt,
  }) {
    _assertLayerTypeAllowed(category, layerType);
    _assertConditionAllowed(condition);
    return customInsert(
      '''
      INSERT INTO items (
        name, category, subtype, brand, price, size, layer_type, condition,
        season, fabric, notes, color_primary_hex, color_primary_name,
        color_secondary_hex, color_secondary_name, image_path, cutout_path,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable(name),
        Variable(category.name),
        Variable(subtype),
        Variable(brand),
        Variable(price),
        Variable(size),
        Variable(layerType?.name),
        Variable(condition?.dbValue),
        Variable(season.name),
        Variable(fabric),
        Variable(notes),
        Variable(colorPrimaryHex),
        Variable(colorPrimaryName),
        Variable(colorSecondaryHex),
        Variable(colorSecondaryName),
        Variable(imagePath),
        Variable(cutoutPath),
        Variable(
          (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
        ),
      ],
    );
  }

  Future<Item?> getItem(int id) async {
    final rows = await customSelect(
      'SELECT * FROM items WHERE id = ?',
      variables: [Variable(id)],
    ).get();
    return rows.isEmpty ? null : _itemFromRow(rows.first);
  }

  /// All items, newest first (the wardrobe grid's default sort).
  Future<List<Item>> getAllItems() async {
    final rows = await customSelect(
      'SELECT * FROM items ORDER BY created_at DESC, id DESC',
    ).get();
    return rows.map(_itemFromRow).toList();
  }

  Future<List<Item>> getItemsByCategory(Category category) async {
    final rows = await customSelect(
      'SELECT * FROM items WHERE category = ? ORDER BY created_at DESC',
      variables: [Variable(category.name)],
    ).get();
    return rows.map(_itemFromRow).toList();
  }

  /// Rewrites all editable fields of an item from its model.
  Future<void> updateItem(Item item) {
    _assertLayerTypeAllowed(item.category, item.layerType);
    _assertConditionAllowed(item.condition);
    return customStatement(
      '''
      UPDATE items SET
        name = ?, category = ?, subtype = ?, brand = ?, price = ?,
        size = ?, layer_type = ?, condition = ?, season = ?, fabric = ?,
        notes = ?, color_primary_hex = ?, color_primary_name = ?,
        color_secondary_hex = ?, color_secondary_name = ?,
        image_path = ?, cutout_path = ?
      WHERE id = ?
      ''',
      [
        item.name,
        item.category.name,
        item.subtype,
        item.brand,
        item.price,
        item.size,
        item.layerType?.name,
        item.condition?.dbValue,
        item.season.name,
        item.fabric,
        item.notes,
        item.colorPrimaryHex,
        item.colorPrimaryName,
        item.colorSecondaryHex,
        item.colorSecondaryName,
        item.imagePath,
        item.cutoutPath,
        item.id,
      ],
    );
  }

  /// Deletes an item and its outfit_items rows in one transaction. The
  /// outfit itself keeps its other slots (the emptied slot renders as a
  /// dashed "missing item" placeholder per userFlow.md).
  Future<void> deleteItem(int id) {
    return transaction(() async {
      await customStatement(
        'DELETE FROM outfit_items WHERE item_id = ?',
        [id],
      );
      await customStatement('DELETE FROM items WHERE id = ?', [id]);
    });
  }

  Future<int> countItems() async {
    final rows = await customSelect('SELECT COUNT(*) AS c FROM items').get();
    return rows.first.read<int>('c');
  }

  // ---------------------------------------------------------------- outfits

  /// Inserts an outfit and returns its generated id.
  ///
  /// [name] is optional; the UI defaults it to something like
  /// "Outfit · Nov 9" per userFlow.md flow 5.
  Future<int> insertOutfit(String name, {DateTime? createdAt}) {
    return customInsert(
      'INSERT INTO outfits (name, created_at) VALUES (?, ?)',
      variables: [
        Variable(name),
        Variable((createdAt ?? DateTime.now()).millisecondsSinceEpoch),
      ],
    );
  }

  Future<List<Outfit>> getAllOutfits() async {
    final rows = await customSelect(
      'SELECT * FROM outfits ORDER BY created_at DESC, id DESC',
    ).get();
    return rows.map(_outfitFromRow).toList();
  }

  Future<Outfit?> getOutfit(int id) async {
    final rows = await customSelect(
      'SELECT * FROM outfits WHERE id = ?',
      variables: [Variable(id)],
    ).get();
    return rows.isEmpty ? null : _outfitFromRow(rows.first);
  }

  Future<void> deleteOutfit(int id) {
    return transaction(() async {
      await customStatement(
        'DELETE FROM outfit_items WHERE outfit_id = ?',
        [id],
      );
      await customStatement('DELETE FROM outfits WHERE id = ?', [id]);
    });
  }

  /// Puts [itemId] into [slot] of the outfit, enforcing the documented
  /// invariant in code (docs/backend.md 2.1): a dress is present if and only
  /// if neither top nor bottom is. Setting a dress clears top and bottom;
  /// setting a top or bottom clears the dress.
  Future<void> setOutfitSlot(int outfitId, int itemId, OutfitSlot slot) {
    return transaction(() async {
      if (slot == OutfitSlot.dress) {
        await customStatement(
          "DELETE FROM outfit_items WHERE outfit_id = ? AND slot IN ('top','bottom')",
          [outfitId],
        );
      } else if (slot == OutfitSlot.top || slot == OutfitSlot.bottom) {
        await customStatement(
          'DELETE FROM outfit_items WHERE outfit_id = ? AND slot = ?',
          [outfitId, OutfitSlot.dress.name],
        );
      }
      await customStatement(
        'INSERT OR REPLACE INTO outfit_items (outfit_id, item_id, slot) VALUES (?, ?, ?)',
        [outfitId, itemId, slot.name],
      );
    });
  }

  /// Empties one slot (leaving the outfit without that piece).
  Future<void> removeOutfitSlot(int outfitId, OutfitSlot slot) {
    return customStatement(
      'DELETE FROM outfit_items WHERE outfit_id = ? AND slot = ?',
      [outfitId, slot.name],
    );
  }

  Future<List<OutfitEntry>> getOutfitItems(int outfitId) async {
    final rows = await customSelect(
      'SELECT * FROM outfit_items WHERE outfit_id = ?',
      variables: [Variable(outfitId)],
    ).get();
    return rows.map(_entryFromRow).toList();
  }

  /// Every outfit_items row in the wardrobe. The suggestion UI uses this to
  /// skip incomplete outfits (userFlow.md edge behaviors).
  Future<List<OutfitEntry>> getAllOutfitItems() async {
    final rows = await customSelect('SELECT * FROM outfit_items').get();
    return rows.map(_entryFromRow).toList();
  }

  /// Renames an outfit in place, keeping its id and creation date.
  Future<void> renameOutfit(int outfitId, String name) {
    return customStatement(
      'UPDATE outfits SET name = ? WHERE id = ?',
      [name, outfitId],
    );
  }

  // ------------------------------------------------------------- app settings

  /// Reads one app-level preference (schema v3 `app_settings`), or null
  /// when unset.
  Future<String?> getSetting(String key) async {
    final rows = await customSelect(
      'SELECT value FROM app_settings WHERE key = ?',
      variables: [Variable(key)],
    ).get();
    return rows.isEmpty ? null : rows.first.read<String>('value');
  }

  /// Writes one app-level preference (insert or replace). customStatement
  /// takes plain values, not drift Variables.
  Future<void> setSetting(String key, String value) {
    return customStatement(
      'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  // ---------------------------------------------------------------- mapping

  Item _itemFromRow(QueryRow row) {
    return Item(
      id: row.read<int>('id'),
      name: row.read<String>('name'),
      category: categoryFromDb(row.read<String>('category')),
      subtype: row.readNullable<String>('subtype'),
      brand: row.readNullable<String>('brand'),
      price: row.readNullable<double>('price'),
      size: row.readNullable<String>('size'),
      layerType: layerTypeFromDb(row.readNullable<String>('layer_type')),
      condition: conditionFromDb(row.readNullable<String>('condition')),
      season: seasonFromDb(row.read<String>('season')),
      fabric: row.readNullable<String>('fabric'),
      notes: row.readNullable<String>('notes'),
      colorPrimaryHex: row.read<String>('color_primary_hex'),
      colorPrimaryName: row.readNullable<String>('color_primary_name'),
      colorSecondaryHex: row.readNullable<String>('color_secondary_hex'),
      colorSecondaryName: row.readNullable<String>('color_secondary_name'),
      imagePath: row.read<String>('image_path'),
      cutoutPath: row.read<String>('cutout_path'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
    );
  }

  Outfit _outfitFromRow(QueryRow row) {
    return Outfit(
      id: row.read<int>('id'),
      name: row.read<String>('name'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
    );
  }

  OutfitEntry _entryFromRow(QueryRow row) {
    return OutfitEntry(
      outfitId: row.read<int>('outfit_id'),
      itemId: row.read<int>('item_id'),
      slot: outfitSlotFromDb(row.read<String>('slot')),
    );
  }
}

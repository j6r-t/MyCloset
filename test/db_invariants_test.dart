import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/models/enums.dart';

/// Database invariant tests (docs/backend.md sections 2.1 and 8):
/// - dress XOR top+bottom exclusivity per outfit
/// - deleting an item cascades into outfit_items
/// - schema CHECK constraints and defaults hold
/// - the v1 -> v2 migration preserves rows and adds the new columns
void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // First query runs onCreate, building schema v2.
    await db.customStatement('SELECT 1');
  });

  tearDown(() async {
    await db.close();
  });

  int nextId = 0;

  Future<int> insertItemWire(Category category,
      {Season season = Season.all}) {
    nextId++;
    return db.insertItem(
      name: 'Item $nextId',
      category: category,
      season: season,
      colorPrimaryHex: '#1C2B4A',
      imagePath: 'original.jpg',
      cutoutPath: 'cutout.png',
    );
  }

  Future<int> insertOutfitWire() => db.insertOutfit('Outfit');

  group('schema (backend.md 2.1)', () {
    test('season defaults to all', () async {
      await db.customStatement('''
        INSERT INTO items (
          name, category, color_primary_hex, image_path, cutout_path, created_at
        ) VALUES ('Raw', 'top', '#1C2B4A', 'o.jpg', 'c.png', 0)
      ''');
      final rows = await db.customSelect(
        'SELECT season FROM items',
      ).get();
      expect(rows.single.read<String>('season'), 'all');
    });

    test('invalid category values are rejected by CHECK', () async {
      expect(
        () => db.customStatement('''
          INSERT INTO items (
            name, category, color_primary_hex, image_path, cutout_path, created_at
          ) VALUES ('Bad', 'hat', '#1C2B4A', 'o.jpg', 'c.png', 0)
        '''),
        throwsA(anything),
      );
    });

    test('invalid outfit slots are rejected by CHECK', () async {
      final outfitId = await insertOutfitWire();
      final itemId = await insertItemWire(Category.top);
      expect(
        () => db.customStatement(
          'INSERT INTO outfit_items (outfit_id, item_id, slot) VALUES (?, ?, ?)',
          [outfitId, itemId, 'belt'],
        ),
        throwsA(anything),
      );
    });

    test('one item per slot per outfit (primary key)', () async {
      final outfitId = await insertOutfitWire();
      final topA = await insertItemWire(Category.top);
      final topB = await insertItemWire(Category.top);

      await db.setOutfitSlot(outfitId, topA, OutfitSlot.top);
      await db.setOutfitSlot(outfitId, topB, OutfitSlot.top);

      final entries = await db.getOutfitItems(outfitId);
      expect(entries, hasLength(1));
      expect(entries.single.itemId, topB);
    });
  });

  group('dress XOR top+bottom invariant (backend.md 2.1)', () {
    test('setting a dress clears top and bottom', () async {
      final outfitId = await insertOutfitWire();
      final dress = await insertItemWire(Category.dress);
      final top = await insertItemWire(Category.top);
      final bottom = await insertItemWire(Category.bottom);

      await db.setOutfitSlot(outfitId, top, OutfitSlot.top);
      await db.setOutfitSlot(outfitId, bottom, OutfitSlot.bottom);
      expect(await db.getOutfitItems(outfitId), hasLength(2));

      await db.setOutfitSlot(outfitId, dress, OutfitSlot.dress);
      final entries = await db.getOutfitItems(outfitId);
      expect(entries, hasLength(1));
      expect(entries.single.slot, OutfitSlot.dress);
      expect(entries.single.itemId, dress);
    });

    test('setting top or bottom clears the dress', () async {
      final outfitId = await insertOutfitWire();
      final dress = await insertItemWire(Category.dress);
      final top = await insertItemWire(Category.top);
      final bottom = await insertItemWire(Category.bottom);

      await db.setOutfitSlot(outfitId, dress, OutfitSlot.dress);
      await db.setOutfitSlot(outfitId, top, OutfitSlot.top);
      await db.setOutfitSlot(outfitId, bottom, OutfitSlot.bottom);

      final slots = (await db.getOutfitItems(outfitId))
          .map((e) => e.slot)
          .toSet();
      expect(slots, {OutfitSlot.top, OutfitSlot.bottom});
    });

    test('outerwear, shoes and accessory coexist with dress', () async {
      final outfitId = await insertOutfitWire();
      final dress = await insertItemWire(Category.dress);
      final shoes = await insertItemWire(Category.shoes);
      final outerwear = await insertItemWire(Category.outerwear);
      final accessory = await insertItemWire(Category.accessory);

      await db.setOutfitSlot(outfitId, dress, OutfitSlot.dress);
      await db.setOutfitSlot(outfitId, shoes, OutfitSlot.shoes);
      await db.setOutfitSlot(outfitId, outerwear, OutfitSlot.outerwear);
      await db.setOutfitSlot(outfitId, accessory, OutfitSlot.accessory);

      expect(await db.getOutfitItems(outfitId), hasLength(4));
    });
  });

  group('cascade delete (backend.md 2.1)', () {
    test('deleting an item removes its outfit_items rows, keeps the outfit',
        () async {
      final outfitId = await insertOutfitWire();
      final top = await insertItemWire(Category.top);
      final bottom = await insertItemWire(Category.bottom);
      final shoes = await insertItemWire(Category.shoes);

      await db.setOutfitSlot(outfitId, top, OutfitSlot.top);
      await db.setOutfitSlot(outfitId, bottom, OutfitSlot.bottom);
      await db.setOutfitSlot(outfitId, shoes, OutfitSlot.shoes);

      await db.deleteItem(top);

      expect(await db.getItem(top), isNull);
      final entries = await db.getOutfitItems(outfitId);
      expect(entries.map((e) => e.slot).toSet(),
          {OutfitSlot.bottom, OutfitSlot.shoes});
      expect(await db.getOutfit(outfitId), isNotNull);
    });

    test('deleting an outfit removes all its slot rows', () async {
      final outfitId = await insertOutfitWire();
      final top = await insertItemWire(Category.top);
      final shoes = await insertItemWire(Category.shoes);
      await db.setOutfitSlot(outfitId, top, OutfitSlot.top);
      await db.setOutfitSlot(outfitId, shoes, OutfitSlot.shoes);

      await db.deleteOutfit(outfitId);

      expect(await db.getOutfit(outfitId), isNull);
      expect(await db.getAllOutfitItems(), isEmpty);
      // The items themselves survive.
      expect(await db.getItem(top), isNotNull);
    });

    test('foreign key cascade also works without the explicit delete', () async {
      // PRAGMA foreign_keys is enabled in beforeOpen; the ON DELETE CASCADE
      // clauses in the DDL must catch direct item deletions too.
      final outfitId = await insertOutfitWire();
      final top = await insertItemWire(Category.top);
      await db.setOutfitSlot(outfitId, top, OutfitSlot.top);

      await db.customStatement('DELETE FROM items WHERE id = ?', [top]);

      expect(await db.getAllOutfitItems(), isEmpty);
    });
  });

  group('schema v2 columns (backend.md 2.1)', () {
    test('fresh install enforces the layer_type CHECK in the DDL', () async {
      // The DDL CHECK validates the layer_type value itself; the rule that
      // layer_type is only set on top/outerwear lives at app level
      // (_assertLayerTypeAllowed) and is tested separately.
      expect(
        () => db.customStatement('''
          INSERT INTO items (
            name, category, layer_type, color_primary_hex,
            image_path, cutout_path, created_at
          ) VALUES ('Raw', 'top', 'outermost', '#1C2B4A', 'o.jpg', 'c.png', 0)
        '''),
        throwsA(anything),
      );
      await db.customStatement('''
        INSERT INTO items (
          name, category, layer_type, color_primary_hex,
          image_path, cutout_path, created_at
        ) VALUES ('Ok', 'top', 'both', '#1C2B4A', 'o.jpg', 'c.png', 0)
      ''');
    });

    test('layer_type is rejected for non-layering categories on insert',
        () async {
      expect(
        () => db.insertItem(
          name: 'Jeans',
          category: Category.bottom,
          layerType: LayerType.outer,
          colorPrimaryHex: '#1C2B4A',
          imagePath: 'o.jpg',
          cutoutPath: 'c.png',
        ),
        throwsArgumentError,
      );
      // A layering category accepts it.
      final id = await db.insertItem(
        name: 'Blazer',
        category: Category.outerwear,
        layerType: LayerType.outer,
        colorPrimaryHex: '#1C2B4A',
        imagePath: 'o.jpg',
        cutoutPath: 'c.png',
      );
      expect((await db.getItem(id))!.layerType, LayerType.outer);
    });

    test('layer_type is rejected for non-layering categories on update',
        () async {
      final id = await db.insertItem(
        name: 'Skirt',
        category: Category.bottom,
        colorPrimaryHex: '#1C2B4A',
        imagePath: 'o.jpg',
        cutoutPath: 'c.png',
      );
      final item = (await db.getItem(id))!;
      expect(
        () => db.updateItem(item.copyWith(layerType: LayerType.both)),
        throwsArgumentError,
      );
    });
  });

  group('v1 -> v2 migration (backend.md 2.1)', () {
    test('upgrades a real v1 file, preserving rows and gaining columns',
        () async {
      final temp = await Directory.systemTemp.createTemp('mycloset_mig_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final dbFile = File(
        '${temp.path}${Platform.pathSeparator}legacy.sqlite',
      );

      // Build a genuine schema v1 database: drift stamps user_version = 1
      // on create, exactly like the previously shipped build did. The v1
      // DDL comes from the AppDatabase.schemaV1Statements fixture.
      final legacy = _LegacyV1Database(NativeDatabase(dbFile));
      await legacy.customSelect('SELECT 1').get();
      await legacy.customStatement('''
        INSERT INTO items (
          name, category, color_primary_hex, image_path, cutout_path,
          created_at
        ) VALUES ('Old tee', 'top', '#1C2B4A', 'o.jpg', 'c.png', 1700000000000)
      ''');
      await legacy.customStatement('''
        INSERT INTO items (
          name, category, color_primary_hex, image_path, cutout_path,
          created_at
        ) VALUES ('Old coat', 'outerwear', '#8A8A8A', 'o2.jpg', 'c2.png', 1700000001000)
      ''');
      await legacy.close();

      // Opening through AppDatabase runs the v1 -> v2 migration.
      final migrated = AppDatabase(NativeDatabase(dbFile));
      final version = await migrated
          .customSelect('PRAGMA user_version')
          .get()
          .then((rows) => rows.first.read<int>('user_version'));
      expect(version, 2);

      // Rows survived with nulls in the new columns.
      final items = await migrated.getAllItems();
      expect(items, hasLength(2));
      for (final item in items) {
        expect(item.size, isNull);
        expect(item.layerType, isNull);
      }

      // The new columns are usable after the migration.
      final tee = items.firstWhere((i) => i.name == 'Old tee');
      await migrated.updateItem(
        tee.copyWith(size: 'M', layerType: LayerType.both),
      );
      final updated = (await migrated.getItem(tee.id))!;
      expect(updated.size, 'M');
      expect(updated.layerType, LayerType.both);

      // Fresh inserts use the full v2 write path.
      final newId = await migrated.insertItem(
        name: 'New shirt',
        category: Category.top,
        size: 'L',
        layerType: LayerType.outer,
        colorPrimaryHex: '#FFFFFF',
        imagePath: 'o3.jpg',
        cutoutPath: 'c3.png',
      );
      final fresh = (await migrated.getItem(newId))!;
      expect(fresh.size, 'L');
      expect(fresh.layerType, LayerType.outer);

      await migrated.close();
    });
  });

  group('typed round trip', () {
    test('item fields survive insert/read/update', () async {
      final id = await db.insertItem(
        name: 'White tee',
        category: Category.top,
        subtype: 't-shirt',
        brand: 'SomeBrand',
        price: 49.9,
        size: 'M',
        layerType: LayerType.both,
        season: Season.summer,
        fabric: 'cotton',
        notes: 'favorite',
        colorPrimaryHex: '#FAFAFA',
        colorPrimaryName: 'white',
        colorSecondaryHex: '#1C2B4A',
        colorSecondaryName: 'navy',
        imagePath: 'o.jpg',
        cutoutPath: 'c.png',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      final item = (await db.getItem(id))!;
      expect(item.name, 'White tee');
      expect(item.category, Category.top);
      expect(item.subtype, 't-shirt');
      expect(item.brand, 'SomeBrand');
      expect(item.price, 49.9);
      expect(item.size, 'M');
      expect(item.layerType, LayerType.both);
      expect(item.season, Season.summer);
      expect(item.fabric, 'cotton');
      expect(item.notes, 'favorite');
      expect(item.colorPrimaryName, 'white');
      expect(item.colorSecondaryHex, '#1C2B4A');
      expect(
        item.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      final edited = item.copyWith(name: 'White tee v2', price: 39.9);
      await db.updateItem(edited);
      final reread = (await db.getItem(id))!;
      expect(reread.name, 'White tee v2');
      expect(reread.price, 39.9);
      expect(reread.category, Category.top);
      // copyWith keeps untouched v2 fields.
      expect(reread.size, 'M');
      expect(reread.layerType, LayerType.both);

      expect(await db.countItems(), 1);
      expect(await db.getItemsByCategory(Category.top), hasLength(1));
      expect(await db.getItemsByCategory(Category.dress), isEmpty);
    });

    test('getAllItems sorts newest first', () async {
      final old = await db.insertItem(
        name: 'Old',
        category: Category.top,
        colorPrimaryHex: '#000000',
        imagePath: 'a',
        cutoutPath: 'a',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final newer = await db.insertItem(
        name: 'Newer',
        category: Category.bottom,
        colorPrimaryHex: '#000000',
        imagePath: 'b',
        cutoutPath: 'b',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      final all = await db.getAllItems();
      expect(all.map((i) => i.id).toList(), [newer, old]);
    });
  });
}

/// Throwaway drift database that creates schema v1 from
/// [AppDatabase.schemaV1Statements] and stamps user_version = 1. Used only
/// to produce a genuine v1 database file for the migration test.
class _LegacyV1Database extends drift.GeneratedDatabase {
  _LegacyV1Database(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<drift.TableInfo> get allTables => const [];

  @override
  drift.MigrationStrategy get migration => drift.MigrationStrategy(
        onCreate: (m) async {
          for (final statement in AppDatabase.schemaV1Statements) {
            await customStatement(statement);
          }
        },
      );
}

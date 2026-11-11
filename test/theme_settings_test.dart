// Theme mode persistence (schema v3 app_settings table) plus the outfit
// detail component rows.
//
// - the settings table round-trips values, defaults to null when unset, and
//   is created by the v1 -> v3 migration on legacy files;
// - a persisted theme_mode string is restored through AppState.load();
// - the outfit detail screen renders one component row per garment with the
//   documented fields (design.md section 6.6 detail extension).
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/models/enums.dart';
import 'package:my_closet/screens/outfit_detail_screen.dart';
import 'package:my_closet/services/file_storage_service.dart';
import 'package:my_closet/ui/app_state.dart';
import 'package:my_closet/ui/theme.dart';

Future<Directory> _tempDir() => Directory.systemTemp.createTemp('mycloset_t_');

void main() {
  group('app_settings (schema v3)', () {
    late AppDatabase db;
    Directory? temp;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      // First query runs onCreate, building schema v3.
      await db.customStatement('SELECT 1');
    });

    tearDown(() async {
      await db.close();
      temp?.deleteSync(recursive: true);
      temp = null;
    });

    test('getSetting returns null when unset', () async {
      expect(await db.getSetting('theme_mode'), isNull);
    });

    test('theme mode string round-trips', () async {
      await db.setSetting('theme_mode', ThemeMode.dark.name);
      expect(await db.getSetting('theme_mode'), 'dark');

      await db.setSetting('theme_mode', ThemeMode.light.name);
      // INSERT OR REPLACE: one row per key, latest value wins.
      expect(await db.getSetting('theme_mode'), 'light');
      final rows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM app_settings',
      ).get();
      expect(rows.first.read<int>('c'), 1);
    });

    test('v1 file migrates to v3 and gains a usable app_settings table',
        () async {
      temp = await _tempDir();
      final dbFile = File(
        '${temp!.path}${Platform.pathSeparator}legacy.sqlite',
      );

      final legacy = _LegacyV1Database(NativeDatabase(dbFile));
      await legacy.customSelect('SELECT 1').get();
      await legacy.close();

      final migrated = AppDatabase(NativeDatabase(dbFile));
      expect(await migrated.getSetting('theme_mode'), isNull);
      await migrated.setSetting('theme_mode', 'dark');
      expect(await migrated.getSetting('theme_mode'), 'dark');
      await migrated.close();
    });
  });

  group('AppState theme mode', () {
    late AppDatabase db;
    late Directory temp;
    late AppState state;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.customStatement('SELECT 1');
      temp = await _tempDir();
      state = AppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
    });

    tearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });

    test('defaults to system when nothing is stored', () async {
      await state.load();
      expect(state.themeMode, ThemeMode.system);
    });

    test('setThemeMode persists and load() restores the choice', () async {
      await state.load();
      await state.setThemeMode(ThemeMode.dark);
      expect(state.themeMode, ThemeMode.dark);
      expect(await db.getSetting('theme_mode'), 'dark');

      // A fresh state (like the next app start) restores it.
      final fresh = AppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      await fresh.load();
      expect(fresh.themeMode, ThemeMode.dark);
    });
  });

  group('outfit detail component rows', () {
    late AppDatabase db;
    late Directory temp;
    late AppState state;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.customStatement('SELECT 1');
      temp = await _tempDir();
      state = AppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      // Two items joined into one outfit, loaded through the real path.
      final topId = await db.insertItem(
        name: 'Navy tee',
        category: Category.top,
        brand: 'BrandX',
        price: 49.9,
        size: 'M',
        layerType: LayerType.inner,
        colorPrimaryHex: '#1C2B4A',
        colorPrimaryName: 'navy',
        imagePath: 'o.jpg',
        cutoutPath: 'c.png',
      );
      final shoesId = await db.insertItem(
        name: 'White sneakers',
        category: Category.shoes,
        brand: 'BrandX',
        colorPrimaryHex: '#FFFFFF',
        colorPrimaryName: 'white',
        imagePath: 'o.jpg',
        cutoutPath: 'c.png',
      );
      final outfitId = await db.insertOutfit('Casual');
      await db.setOutfitSlot(outfitId, topId, OutfitSlot.top);
      await db.setOutfitSlot(outfitId, shoesId, OutfitSlot.shoes);
      await state.load();
    });

    tearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });

    testWidgets('renders one row per garment with its details',
        (tester) async {
      // Tall surface so the whole ListView (flat lay + component rows)
      // builds - ListView only materializes visible children.
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: AppStateScope(
            state: state,
            child: OutfitDetailScreen(
              outfitId: state.outfits.first.id,
            ),
          ),
        ),
      );
      await tester.pump();

      // Name, section label, harmony readout (two items -> a bucket word).
      expect(find.text('Casual'), findsOneWidget);
      expect(find.text('Pieces'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'Harmonious|Mixed|Clashing')),
        findsOneWidget,
      );
      // Component rows: names, slot labels, brand, price, layer type.
      expect(find.text('Navy tee'), findsOneWidget);
      expect(find.text('White sneakers'), findsOneWidget);
      expect(find.text('BrandX'), findsNWidgets(2));
      expect(find.text('49.90 USD/EUR'), findsOneWidget);
      expect(find.textContaining('Layer: inner'), findsOneWidget);
      // Per-row affordances: one edit next to the name plus one edit and
      // one delete per garment row.
      expect(find.byIcon(AppIcons.edit), findsNWidgets(3));
      expect(find.byIcon(AppIcons.delete), findsNWidgets(2));
    });
  });
}

/// Throwaway drift database that creates schema v1 from
/// [AppDatabase.schemaV1Statements] and stamps user_version = 1.
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

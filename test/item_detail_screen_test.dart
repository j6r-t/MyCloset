// The item detail screen's Color row swatch bubbles. Two bugs live here:
// 1. `Color(int.parse('RRGGBB', radix: 16))` yields 0x00RRGGBB - alpha 0,
//    a fully transparent bubble (the "colors not appearing in the
//    bubbles" bug). The fill must be opaque.
// 2. The outline used the hairline token (#ECECED), which let even an
//    opaque white bubble vanish into the white page. It must be stronger.
//
// A real AppState over an in-memory database (same pattern as
// details_form_screen_test.dart); the cutout file does not exist, which
// the hero image handles via its error placeholder. The metadata table
// sits below the hero card, so both tests scroll it into view first (the
// detail list is a lazy ListView - unbuilt rows are invisible to finders).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/models/enums.dart';
import 'package:my_closet/screens/item_detail_screen.dart';
import 'package:my_closet/services/file_storage_service.dart';
import 'package:my_closet/ui/app_state.dart';
import 'package:my_closet/ui/theme.dart';

void main() {
  late AppDatabase db;
  late Directory temp;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('SELECT 1');
    temp = await Directory.systemTemp.createTemp('mycloset_detail_');
  });

  tearDown(() async {
    await db.close();
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        temp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  });

  AppState stubState() => AppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );

  /// Inserts the item row directly through the (in-memory) database: the
  /// real save path writes draft files to disk, which is the documented
  /// testWidgets hang in details_form_screen_test.dart - this file's IO
  /// must stay on the in-memory DB only. The item's image paths point at
  /// missing files on purpose; the hero shows its error placeholder.
  Future<int> insertItem({String primaryHex = '#FFFFFF'}) => db.insertItem(
        name: 'White tee',
        category: Category.top,
        colorPrimaryHex: primaryHex,
        colorPrimaryName: 'white',
        imagePath: '${temp.path}/missing.jpg',
        cutoutPath: '${temp.path}/missing_cutout.png',
      );

  testWidgets('primary and accent bubbles render with a visible outline',
      (tester) async {
    final state = stubState();
    final id = await insertItem(primaryHex: '#FFFFFF');
    await db.customStatement(
      'UPDATE items SET color_secondary_hex = ?, color_secondary_name = ? '
      'WHERE id = ?',
      ['#FF0000', 'scarlet', id],
    );
    await state.load();
    final item = state.itemById(id)!;

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(),
          home: ItemDetailScreen(item: item),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('swatch-secondary')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final primary = tester.widget<Container>(
      find.byKey(const ValueKey('swatch-primary')),
    );
    final accent = tester.widget<Container>(
      find.byKey(const ValueKey('swatch-secondary')),
    );

    // Actual saved hexes drive the fill.
    expect(
      (primary.decoration as BoxDecoration).color,
      const Color(0xFFFFFFFF),
    );
    expect(
      (accent.decoration as BoxDecoration).color,
      const Color(0xFFFF0000),
    );

    // The outline must NOT be the hairline token: hairline (#ECECED) is
    // what let white bubbles vanish into the white page.
    final outline =
        ((primary.decoration as BoxDecoration).border as Border).top.color;
    expect(outline, isNot(AppColors.light.hairline));
  });

  testWidgets('a single-color item renders exactly one bubble',
      (tester) async {
    final state = stubState();
    final id = await insertItem(primaryHex: '#1C2B4A');
    await state.load();
    final item = state.itemById(id)!;

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(),
          home: ItemDetailScreen(item: item),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('swatch-primary')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('swatch-primary')), findsOneWidget);
    expect(find.byKey(const ValueKey('swatch-secondary')), findsNothing);
  });
}

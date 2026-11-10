// Settings round-trip for the online identification API keys: values persist
// in app_settings (schema v3), the set/unset flags refresh without ever
// exposing the stored values to the UI, and a fresh AppState (next app start)
// restores the flags. runIdentification without keys returns the graceful
// unavailable result without any HTTP.
//
// The second group covers the details form as a pure receiver: the
// identification screen owns running the lookup now, so the form only
// applies a passed-in prefill to EMPTY fields (brief "auto" chips), shows
// the setup caption when opened without keys, and stays silent in edit
// mode. The lookup itself (loading, failure, retry) is covered in
// identification_screen_test.dart.
//
// No real key material appears in this file.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/models/enums.dart';
import 'package:my_closet/models/item.dart';
import 'package:my_closet/screens/details_form_screen.dart';
import 'package:my_closet/services/file_storage_service.dart';
import 'package:my_closet/services/identification_pipeline.dart';
import 'package:my_closet/ui/app_state.dart';
import 'package:my_closet/ui/theme.dart';

/// Test-only placeholder. Never a real credential.
const _testKey = 'test-key-placeholder';

void main() {
  late AppDatabase db;
  late Directory temp;
  late AppState state;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // First query runs onCreate, building schema v3.
    await db.customStatement('SELECT 1');
    temp = await Directory.systemTemp.createTemp('mycloset_keys_');
    state = AppState(
      database: db,
      storage: FileStorageService(documentsDir: () async => temp),
    );
    await state.load();
  });

  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  group('API key round-trip', () {
    test('flags start unset and getters return null', () async {
      expect(state.serpApiKeySet, isFalse);
      expect(state.visionApiKeySet, isFalse);
      expect(await state.getSerpApiKey(), isNull);
      expect(await state.getVisionApiKey(), isNull);
    });

    test('setSerpApiKey persists and restores through a fresh load',
        () async {
      await state.setSerpApiKey('  $_testKey  ');
      expect(state.serpApiKeySet, isTrue);
      // Trimmed before storage; the value itself round-trips.
      expect(await state.getSerpApiKey(), _testKey);

      final fresh = AppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      await fresh.load();
      expect(fresh.serpApiKeySet, isTrue);
      expect(await fresh.getSerpApiKey(), _testKey);
    });

    test('setting both keys updates both flags independently', () async {
      await state.setSerpApiKey(_testKey);
      expect(state.serpApiKeySet, isTrue);
      expect(state.visionApiKeySet, isFalse);

      await state.setVisionApiKey(_testKey);
      expect(state.visionApiKeySet, isTrue);
      expect(await state.getVisionApiKey(), _testKey);
    });

    test('saving an empty string clears the key and the flag', () async {
      await state.setVisionApiKey(_testKey);
      expect(state.visionApiKeySet, isTrue);

      await state.setVisionApiKey('   ');
      expect(state.visionApiKeySet, isFalse);
      expect(await state.getVisionApiKey(), isNull);
    });

    test(
        'runIdentification without keys returns the unavailable result with '
        'no throw', () async {
      final result = await state.runIdentification(
        imagePath: '${temp.path}${Platform.pathSeparator}whatever.png',
      );
      expect(result.ok, isFalse);
      expect(result.matches, isEmpty);
      expect(result.notes.single, contains('No API keys set'));
    });
  });

  group('details form prefill', () {
    // Nonexistent path: color extraction and the cutout thumbnail both
    // degrade quietly, which is exactly what the tests rely on.
    const draftPath = 'nonexistent-draft.png';

    Item editItem() => Item(
          id: 7,
          name: 'Blue blazer',
          category: Category.outerwear,
          colorPrimaryHex: '#223344',
          imagePath: 'original.png',
          cutoutPath: 'cutout.png',
          createdAt: DateTime(2026, 11, 10),
        );

    IdentificationResult okResult() => IdentificationResult(
          ok: true,
          matches: const [],
          suggestedBrand: 'Acne Studios',
          suggestedPriceValue: 120,
          notes: const [],
        );

    Future<void> pumpForm(
      WidgetTester tester,
      _StubAppState state, {
      Item? existing,
      IdentificationResult? prefill,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: AppStateScope(
            state: state,
            child: DetailsFormScreen(
              draftOriginalPath: existing == null ? draftPath : null,
              existing: existing,
              prefill: prefill,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    String? fieldValue(WidgetTester tester, String rowKey) {
      final field = find.descendant(
        of: find.byKey(ValueKey(rowKey)),
        matching: find.byType(TextFormField),
      );
      return tester.widget<TextFormField>(field).controller!.text;
    }

    testWidgets('a prefill fills the empty fields with brief auto chips',
        (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );

      await pumpForm(tester, state, prefill: okResult());

      // Brand and price landed; nothing else was touched.
      expect(fieldValue(tester, 'row-brand'), 'Acne Studios');
      expect(fieldValue(tester, 'row-price'), '120.0');
      expect(fieldValue(tester, 'row-subtype'), '');

      // What the search contributed is visible: one "auto" chip per
      // filled row.
      expect(find.text('auto'), findsNWidgets(2));

      // The chips clear after their brief highlight window.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('auto'), findsNothing);
    });

    testWidgets('a prefill never overwrites values a user has set '
        '(edit mode ignores it)', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      state.serpApiKeySet = true;

      // Edit mode: the existing item's values (name present, brand/price
      // unset) must stay exactly as they are - no prefill, no chips, no
      // setup caption.
      await pumpForm(
        tester,
        state,
        existing: editItem(),
        prefill: okResult(),
      );

      expect(fieldValue(tester, 'row-name'), 'Blue blazer');
      expect(fieldValue(tester, 'row-brand'), '');
      expect(fieldValue(tester, 'row-price'), '');
      expect(find.text('auto'), findsNothing);
      expect(state.runCount, 0);
    });

    testWidgets('without keys the add form never runs and shows the '
        'setup caption', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );

      await pumpForm(tester, state);

      // The form is a pure receiver: it never runs the lookup itself.
      expect(state.runCount, 0);
      expect(
        find.text('Add your SerpAPI key in Settings to auto-fill details'),
        findsOneWidget,
      );
      expect(find.text('auto'), findsNothing);
    });

    testWidgets('edit mode shows neither caption nor chips', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );

      await pumpForm(tester, state, existing: editItem());

      expect(state.runCount, 0);
      expect(
        find.text('Add your SerpAPI key in Settings to auto-fill details'),
        findsNothing,
      );
      expect(find.text('auto'), findsNothing);
    });
  });
}

/// AppState double whose identification run is scriptable: counts calls and
/// hands back a canned (or completer-held) result instead of the pipeline.
class _StubAppState extends AppState {
  _StubAppState({required super.database, required super.storage});

  int runCount = 0;

  /// When set, replaces the real pipeline call entirely.
  Future<IdentificationResult> Function()? onRun;

  @override
  Future<IdentificationResult> runIdentification({
    required String imagePath,
    String? categoryLabel,
    String? subtype,
    String? brand,
  }) {
    runCount += 1;
    final custom = onRun;
    if (custom != null) return custom();
    return super.runIdentification(
      imagePath: imagePath,
      categoryLabel: categoryLabel,
      subtype: subtype,
      brand: brand,
    );
  }
}

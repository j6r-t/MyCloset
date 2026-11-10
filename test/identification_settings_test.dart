// Settings round-trip for the online identification API keys: values persist
// in app_settings (schema v3), the set/unset flags refresh without ever
// exposing the stored values to the UI, and a fresh AppState (next app start)
// restores the flags. runIdentification without keys returns the graceful
// unavailable result without any HTTP.
//
// The second group covers the details form's quiet auto-fill (add mode
// opens, the lookup runs in the background, only empty fields take the
// suggestions): auto-run attempts once, keyless and failed outcomes show
// the quiet caption with a one-shot retry, and the old match sheet and its
// button are gone.
//
// No real key material appears in this file.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

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

  group('details form auto-fill', () {
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

    Future<void> pumpForm(
      WidgetTester tester,
      _StubAppState state, {
      Item? existing,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: AppStateScope(
            state: state,
            child: DetailsFormScreen(
              draftOriginalPath: existing == null ? draftPath : null,
              existing: existing,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('add mode auto-runs once, with no button and no sheet',
        (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      state.serpApiKeySet = true;
      final completer = Completer<IdentificationResult>();
      state.onRun = () => completer.future;

      await pumpForm(tester, state);
      await tester.pump();

      // Exactly one background attempt, started at open.
      expect(state.runCount, 1);
      // The old opt-in affordances are gone.
      expect(find.text('Identify online'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      // Quiet per-row progress captions instead.
      expect(find.text('Identifying...'), findsWidgets);

      completer.complete(IdentificationResult(
        ok: true,
        matches: const [],
        notes: const [],
      ));
      await tester.pump();
      // Let the "auto" chip fade timer (2s) run out so no timer is pending.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('without keys the form never runs and shows the setup '
        'caption with a retry affordance', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );

      await pumpForm(tester, state);
      await tester.pump();

      expect(state.runCount, 0);
      expect(
        find.text('Add your SerpAPI key in Settings to auto-fill details'),
        findsOneWidget,
      );
      expect(find.byIcon(Symbols.refresh), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a suggestion fills an empty field and never overwrites a '
        'typed value', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      state.serpApiKeySet = true;
      final completer = Completer<IdentificationResult>();
      state.onRun = () => completer.future;

      await pumpForm(tester, state);
      await tester.pump();

      // The user types a brand while the lookup is still in flight.
      final brandField = find.descendant(
        of: find.byKey(const ValueKey('row-brand')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(brandField, 'Zara');
      await tester.pump();

      completer.complete(IdentificationResult(
        ok: true,
        matches: const [],
        suggestedBrand: 'Acne Studios',
        suggestedPriceValue: 120,
        notes: const [],
      ));
      await tester.pump();

      // Typed value wins; the empty price field takes the suggestion.
      final brandText = tester
          .widget<TextFormField>(brandField)
          .controller!
          .text;
      expect(brandText, 'Zara');
      final priceField = find.descendant(
        of: find.byKey(const ValueKey('row-price')),
        matching: find.byType(TextFormField),
      );
      expect(
        tester.widget<TextFormField>(priceField).controller!.text,
        '120.0',
      );

      // What the search contributed is visible: one "auto" chip (price
      // only - brand kept the user's value).
      expect(find.text('auto'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      // The chip clears after its brief highlight window.
      expect(find.text('auto'), findsNothing);
    });

    testWidgets('failure shows the quiet caption with one retry, then the '
        'retry affordance is spent', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      state.serpApiKeySet = true;
      state.onRun = () async =>
          IdentificationResult.unavailable(const ['No matches anywhere.']);

      await pumpForm(tester, state);
      await tester.pump();

      // One automatic attempt, no modal noise.
      expect(state.runCount, 1);
      expect(
        find.text("Couldn't identify this piece - fill in manually"),
        findsOneWidget,
      );
      expect(find.byIcon(Symbols.refresh), findsOneWidget);

      // The retry affordance re-runs the lookup exactly once.
      await tester.tap(find.byIcon(Symbols.refresh));
      await tester.pump();
      expect(state.runCount, 2);
      expect(find.byIcon(Symbols.refresh), findsNothing);
      expect(
        find.text("Couldn't identify this piece - fill in manually"),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('edit mode never auto-runs identification', (tester) async {
      final state = _StubAppState(
        database: db,
        storage: FileStorageService(documentsDir: () async => temp),
      );
      state.serpApiKeySet = true;

      await pumpForm(tester, state, existing: editItem());
      await tester.pump(const Duration(seconds: 1));

      expect(state.runCount, 0);
      expect(find.text('Identifying...'), findsNothing);
      expect(find.byIcon(Symbols.refresh), findsNothing);
      expect(
        find.text('Add your SerpAPI key in Settings to auto-fill details'),
        findsNothing,
      );
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

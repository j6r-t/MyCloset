// The identification screen (screen 3.5): the explicit loading page between
// the cutout review and the details form.
//
// Covered here: the keyless skip (straight to the details form, which
// carries the setup caption itself), the successful run handing its result
// to the form as a prefill, the not-found outcome (title, per-step reasons,
// "Fill in manually"), the one-shot retry whose pill disappears after the
// second failure, and the manual pill routing to the details form.
//
// The stub AppState makes each outcome deterministic; no real key material
// appears in this file and no HTTP runs.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/screens/details_form_screen.dart';
import 'package:my_closet/screens/identification_screen.dart';
import 'package:my_closet/services/file_storage_service.dart';
import 'package:my_closet/services/identification_pipeline.dart';
import 'package:my_closet/ui/app_state.dart';
import 'package:my_closet/ui/theme.dart';

void main() {
  late AppDatabase db;
  late Directory temp;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // First query runs onCreate, building schema v3.
    await db.customStatement('SELECT 1');
    temp = await Directory.systemTemp.createTemp('mycloset_ident_');
  });

  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  group('identification screen', () {
    // Nonexistent path: the cutout thumbnail and any file read degrade
    // quietly, which is exactly what the tests rely on.
    const draftPath = 'nonexistent-draft.png';

    _StubAppState stubState() => _StubAppState(
          database: db,
          storage: FileStorageService(documentsDir: () async => temp),
        );

    Future<void> pumpScreen(WidgetTester tester, _StubAppState state) async {
      // Same wiring as production (main.dart): the AppStateScope wraps the
      // MaterialApp, so routes pushed later (the details form) see it too.
      await tester.pumpWidget(
        AppStateScope(
          state: state,
          child: MaterialApp(
            theme: buildTheme(),
            home: const IdentificationScreen(draftOriginalPath: draftPath),
          ),
        ),
      );
      // First pump: the post-frame kickoff; second: the lookup's async
      // completion and the resulting navigation.
      await tester.pump();
      await tester.pump();
    }

    String? brandText(WidgetTester tester) {
      final field = find.descendant(
        of: find.byKey(const ValueKey('row-brand')),
        matching: find.byType(TextFormField),
      );
      return tester.widget<TextFormField>(field).controller!.text;
    }

    testWidgets('without keys it skips itself straight to the details form',
        (tester) async {
      final state = stubState();

      await pumpScreen(tester, state);

      // No network attempt at all; the form explains the setup itself.
      expect(state.runCount, 0);
      expect(find.byType(DetailsFormScreen), findsOneWidget);
      expect(
        find.text('Add your SerpAPI key in Settings to auto-fill details'),
        findsOneWidget,
      );
    });

    testWidgets('an ok run opens the details form with the brand prefilled',
        (tester) async {
      final state = stubState();
      state.serpApiKeySet = true;
      state.onRun = () async => IdentificationResult(
            ok: true,
            matches: const [],
            suggestedBrand: 'Acne Studios',
            suggestedPriceValue: 120,
            notes: const [],
          );

      await pumpScreen(tester, state);

      expect(state.runCount, 1);
      expect(find.byType(DetailsFormScreen), findsOneWidget);
      expect(brandText(tester), 'Acne Studios');

      // Let the prefill "auto" chip timer (2s) run out so nothing is
      // pending at the test's end.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a not-found run shows the title, the reasons, and both '
        'actions', (tester) async {
      final state = stubState();
      state.serpApiKeySet = true;
      state.onRun = () async => IdentificationResult.unavailable(
            const ['No matches anywhere.', 'No Vision key set.'],
          );

      await pumpScreen(tester, state);

      expect(state.runCount, 1);
      expect(find.text("Couldn't identify this piece"), findsOneWidget);
      // The result's per-step reasons as the caption.
      expect(
        find.text('No matches anywhere. No Vision key set.'),
        findsOneWidget,
      );
      expect(find.text('Fill in manually'), findsOneWidget);
      expect(find.byIcon(Symbols.refresh), findsOneWidget);
      expect(find.byType(DetailsFormScreen), findsNothing);
    });

    testWidgets('matches without usable detail get the gentler caption',
        (tester) async {
      final state = stubState();
      state.serpApiKeySet = true;
      state.onRun = () async => IdentificationResult.unavailable(
            const ['No recognizable product details in the results.'],
          );

      await pumpScreen(tester, state);

      expect(state.runCount, 1);
      expect(find.text("Couldn't identify this piece"), findsOneWidget);
      expect(
        find.text('Found matches, but nothing we could fill in'),
        findsOneWidget,
      );
      expect(
        find.text('No recognizable product details in the results.'),
        findsNothing,
      );
    });

    testWidgets('the retry pill re-runs once, then disappears', (tester) async {
      final state = stubState();
      state.serpApiKeySet = true;
      state.onRun = () async =>
          IdentificationResult.unavailable(const ['No matches anywhere.']);

      await pumpScreen(tester, state);
      expect(state.runCount, 1);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();

      // Exactly one retry; after the second failure the pill is gone but
      // the outcome stays on screen.
      expect(state.runCount, 2);
      expect(find.byIcon(Symbols.refresh), findsNothing);
      expect(find.text('Try again'), findsNothing);
      expect(find.text("Couldn't identify this piece"), findsOneWidget);
    });

    testWidgets('"Fill in manually" opens the details form without a run',
        (tester) async {
      final state = stubState();
      state.serpApiKeySet = true;
      state.onRun = () async =>
          IdentificationResult.unavailable(const ['No matches anywhere.']);

      await pumpScreen(tester, state);

      await tester.tap(find.text('Fill in manually'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(DetailsFormScreen), findsOneWidget);
      // Keys are set, so the form shows no setup caption and the brand
      // field stays empty for manual entry.
      expect(
        find.text('Add your SerpAPI key in Settings to auto-fill details'),
        findsNothing,
      );
      expect(brandText(tester), '');
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

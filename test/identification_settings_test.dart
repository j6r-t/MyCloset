// Settings round-trip for the online identification API keys: values persist
// in app_settings (schema v3), the set/unset flags refresh without ever
// exposing the stored values to the UI, and a fresh AppState (next app start)
// restores the flags. runIdentification without keys returns the graceful
// unavailable result without any HTTP.
//
// No real key material appears in this file.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/services/file_storage_service.dart';
import 'package:my_closet/ui/app_state.dart';

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
}

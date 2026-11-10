import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/database/app_database.dart';
import 'package:my_closet/models/enums.dart';
import 'package:my_closet/services/backup_service.dart';
import 'package:my_closet/services/file_storage_service.dart';

/// Round-trip test for backup/restore (docs/backend.md section 6) against a
/// real SQLite file and a real temporary documents directory.
void main() {
  late Directory temp;
  late File dbFile;
  late AppDatabase db;
  late BackupService backup;

  Future<int> addItem(String name) {
    return db.insertItem(
      name: name,
      category: Category.top,
      colorPrimaryHex: '#1C2B4A',
      imagePath: 'original.jpg',
      cutoutPath: 'cutout.png',
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mycloset_test_');
    dbFile = File(
      '${temp.path}${Platform.pathSeparator}closet.sqlite',
    );
    db = AppDatabase(NativeDatabase(dbFile));
    await db.customSelect('SELECT 1').get();

    final storage = FileStorageService(documentsDir: () async => temp);
    backup = BackupService(
      database: db,
      storage: storage,
      documentsDir: () async => temp,
    );
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {
      // Already closed by restoreBackup; nothing to do.
    }
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('create, validate and restore round trip', () async {
    final kept = await addItem('Kept in backup');
    await addItem('Also kept');

    // One image file so the images tree is exercised too.
    final imagesDir = Directory(
      '${temp.path}${Platform.pathSeparator}images${Platform.pathSeparator}1',
    );
    await imagesDir.create(recursive: true);
    final imageFile = File(
      '${imagesDir.path}${Platform.pathSeparator}original.jpg',
    );
    await imageFile.writeAsBytes([1, 2, 3], flush: true);

    final zipPath = await backup.createBackup();
    expect(File(zipPath).existsSync(), isTrue);

    final preview = await backup.validateBackup(zipPath);
    expect(preview.valid, isTrue);
    expect(preview.itemCount, 2);
    expect(preview.schemaVersion, 2);

    // Damage the live data, then restore.
    await db.deleteItem(kept);
    expect(await db.countItems(), 1);

    await backup.restoreBackup(zipPath);

    // Restore closes the swapped-out database; reopen on the same file.
    final reopened = AppDatabase(NativeDatabase(dbFile));
    try {
      expect(await reopened.countItems(), 2);
      final restored = await reopened.getItem(kept);
      expect(restored, isNotNull);
      expect(restored!.name, 'Kept in backup');
    } finally {
      await reopened.close();
    }
    expect(imageFile.existsSync(), isTrue);
  });

  test('validation rejects archives without a database', () async {
    final bogus = File(
      '${temp.path}${Platform.pathSeparator}bogus.zip',
    );
    await bogus.writeAsBytes([1, 2, 3, 4], flush: true);

    final preview = await backup.validateBackup(bogus.path);
    expect(preview.valid, isFalse);
  });
}

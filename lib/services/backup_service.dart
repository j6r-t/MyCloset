import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/backends.dart' show QueryExecutor, QueryExecutorUser;
import 'package:drift/drift.dart' show OpeningDetails;
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../database/app_database.dart';
import 'file_storage_service.dart';

/// Thrown when a backup archive is missing, unreadable, or fails validation.
class BackupException implements Exception {
  final String message;
  BackupException(this.message);

  @override
  String toString() => message;
}

/// Summary shown to the user before a restore replaces the current closet.
class RestorePreview {
  final bool valid;
  final String? error;

  /// Schema version the backup was written with.
  final int schemaVersion;

  /// Item count inside the backup (for the confirm dialog, userFlow.md
  /// flow 7: "This replaces your current closet - N items will be removed.").
  final int itemCount;

  const RestorePreview({
    required this.valid,
    this.error,
    required this.schemaVersion,
    required this.itemCount,
  });
}

/// Backup and restore (docs/backend.md section 6).
///
/// Export: snapshot the SQLite file, zip it together with the whole images
/// tree into `backups/closet_backup_<date>.zip`, then hand it to the share
/// sheet.
///
/// Restore: validate the zip (the embedded database opens and its schema
/// version is one this build can migrate from), extract to a staging dir,
/// swap over the live files while keeping the old ones until success.
class BackupService {
  /// Name of the database file inside the archive and in the documents
  /// directory (drift_flutter's default: `<name>.sqlite`).
  static const String dbFileName = 'closet.sqlite';
  static const String dbEntryName = 'closet.db';

  final AppDatabase database;
  final FileStorageService storage;

  /// Resolves the app documents directory; injectable for tests.
  final Future<Directory> Function() documentsDir;

  BackupService({
    required this.database,
    required this.storage,
    Future<Directory> Function()? documentsDir,
  }) : documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  // ----------------------------------------------------------------- export

  /// Creates a backup zip and returns its path. Safe to call while the
  /// database is open: the snapshot comes from `VACUUM INTO`, not from
  /// copying the live file.
  Future<String> createBackup() async {
    final docs = await documentsDir();
    final tmp = await storage.tmpDir();
    final snapshotPath =
        '${tmp.path}${Platform.pathSeparator}closet_snapshot.db';

    final snapshotFile = File(snapshotPath);
    if (snapshotFile.existsSync()) snapshotFile.deleteSync();

    // Escape single quotes so the path can be embedded as an SQL literal.
    final literal = snapshotPath.replaceAll("'", "''");
    await database.customStatement('VACUUM INTO \'$literal\'');

    final archive = Archive();
    final bytes = snapshotFile.readAsBytesSync();
    archive.addFile(
      ArchiveFile(dbEntryName, bytes.length, bytes),
    );

    final imagesDir = Directory(
      '${docs.path}${Platform.pathSeparator}images',
    );
    if (imagesDir.existsSync()) {
      await _addDirectory(archive, imagesDir, 'images');
    }

    final backupPath = await _backupFilePath();
    final zipBytes = ZipEncoder().encode(archive);
    await File(backupPath).writeAsBytes(zipBytes, flush: true);

    snapshotFile.deleteSync();
    return backupPath;
  }

  /// Opens the platform share sheet for a backup zip.
  Future<void> shareBackup(String zipPath) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(zipPath)]),
    );
  }

  Future<String> _backupFilePath() async {
    final backups = await storage.backupsDir();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year.toString()}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '${backups.path}${Platform.pathSeparator}closet_backup_$stamp.zip';
  }

  Future<void> _addDirectory(
    Archive archive,
    Directory dir,
    String entryPrefix,
  ) async {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(dir.path.length + 1);
      final bytes = entity.readAsBytesSync();
      archive.addFile(
        ArchiveFile('$entryPrefix/$relative', bytes.length, bytes),
      );
    }
  }

  // ----------------------------------------------------------------- restore

  /// Validates a backup zip and previews what a restore would do. Never
  /// mutates live data.
  Future<RestorePreview> validateBackup(String zipPath) async {
    final entry = await _readDbEntry(zipPath);
    if (entry == null) {
      return RestorePreview(
        valid: false,
        error: 'No $dbEntryName inside the archive',
        schemaVersion: 0,
        itemCount: 0,
      );
    }

    final tmp = await storage.tmpDir();
    final probePath = '${tmp.path}${Platform.pathSeparator}backup_probe.db';
    final probeFile = File(probePath);
    await probeFile.writeAsBytes(entry, flush: true);

    // The schema version is read straight from the SQLite file header
    // (offset 60, big-endian) instead of through a database connection:
    // every driver stamps its own schema version over user_version when it
    // opens the file, which would destroy the value this method reports.
    final version = _headerUserVersion(entry);
    if (version > database.schemaVersion) {
      return RestorePreview(
        valid: false,
        error: 'Backup was made by a newer app version (schema v$version)',
        schemaVersion: version,
        itemCount: 0,
      );
    }
    if (version < database.schemaVersion) {
      // Older backups are fine: the app migrates them on open (backend.md
      // section 7). Validation just confirms the items table exists.
    }

    final probe = NativeDatabase(probeFile);
    try {
      await probe.ensureOpen(const _ProbeUser());
      final countRows =
          await probe.runSelect('SELECT COUNT(*) AS c FROM items', []);
      return RestorePreview(
        valid: true,
        schemaVersion: version,
        itemCount: countRows.single['c'] as int,
      );
    } catch (e) {
      return RestorePreview(
        valid: false,
        error: 'Backup database is unreadable: $e',
        schemaVersion: version,
        itemCount: 0,
      );
    } finally {
      await probe.close();
      if (probeFile.existsSync()) probeFile.deleteSync();
    }
  }

  /// Reads `PRAGMA user_version` from the SQLite file header (offset 60,
  /// stored big-endian per the SQLite file format spec).
  static int _headerUserVersion(List<int> dbBytes) {
    final data = ByteData.sublistView(Uint8List.fromList(dbBytes));
    return data.getUint32(60, Endian.big);
  }

  /// Restores a backup zip, replacing all current data.
  ///
  /// Closes the live database connection before the swap; the caller must
  /// reopen the database (a fresh `AppDatabase.open()`) afterwards. The old
  /// database and images are kept in tmp until the swap succeeds, then
  /// deleted; on any failure they are rolled back in place.
  Future<void> restoreBackup(String zipPath) async {
    final preview = await validateBackup(zipPath);
    if (!preview.valid) {
      throw BackupException(preview.error ?? 'Invalid backup');
    }

    // Stage the backup contents in tmp.
    final stage = Directory(
      '${(await storage.tmpDir()).path}${Platform.pathSeparator}restore_stage',
    );
    if (stage.existsSync()) stage.deleteSync(recursive: true);
    stage.createSync(recursive: true);

    final archive =
        ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    final stagedDb = File(
      '${stage.path}${Platform.pathSeparator}closet.db',
    );
    final stagedImages = Directory(
      '${stage.path}${Platform.pathSeparator}images',
    );

    for (final entry in archive) {
      if (entry.isFile) {
        if (entry.name == dbEntryName) {
          await stagedDb.writeAsBytes(entry.content as List<int>, flush: true);
        } else if (entry.name.startsWith('images/')) {
          final relative = entry.name.substring('images/'.length);
          final target = File(
            '${stagedImages.path}${Platform.pathSeparator}$relative',
          );
          await target.parent.create(recursive: true);
          await target.writeAsBytes(entry.content as List<int>, flush: true);
        }
      }
    }

    if (!stagedDb.existsSync()) {
      throw BackupException('No $dbEntryName inside the archive');
    }

    // Swap. The live database must be closed before its file moves.
    final docs = await documentsDir();
    final sep = Platform.pathSeparator;
    final liveDb = File('${docs.path}$sep$dbFileName');
    final liveImages = Directory('${docs.path}${sep}images');

    final oldDir = Directory(
      '${(await storage.tmpDir()).path}${Platform.pathSeparator}restore_old',
    );
    if (oldDir.existsSync()) oldDir.deleteSync(recursive: true);
    oldDir.createSync(recursive: true);

    await database.close();

    try {
      if (liveDb.existsSync()) {
        await liveDb.rename('${oldDir.path}$sep$closetOldDbName');
      }
      if (liveImages.existsSync()) {
        await liveImages.rename('${oldDir.path}$sep$_oldImagesName');
      }
      await stagedDb.copy('${docs.path}$sep$dbFileName');
      if (stagedImages.existsSync()) {
        await stagedImages.rename('${docs.path}${sep}images');
      }
    } catch (e) {
      // Roll back: put the old files back before reporting the failure.
      final oldDb = File('${oldDir.path}$sep$closetOldDbName');
      final oldImages = Directory('${oldDir.path}$sep$_oldImagesName');
      if (oldDb.existsSync() && !liveDb.existsSync()) {
        await oldDb.rename('${docs.path}$sep$dbFileName');
      }
      if (oldImages.existsSync() && !liveImages.existsSync()) {
        await oldImages.rename('${docs.path}${sep}images');
      }
      throw BackupException('Restore failed, previous data kept: $e');
    }

    // Success: clean up the kept-old directory and the staging dir.
    if (oldDir.existsSync()) oldDir.deleteSync(recursive: true);
    if (stage.existsSync()) stage.deleteSync(recursive: true);
  }

  Future<List<int>?> _readDbEntry(String zipPath) async {
    final file = File(zipPath);
    if (!file.existsSync()) return null;
    try {
      final archive =
          ZipDecoder().decodeBytes(file.readAsBytesSync());
      for (final entry in archive) {
        if (entry.isFile && entry.name == dbEntryName) {
          return entry.content as List<int>;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static const String closetOldDbName = 'old_closet.sqlite';
  static const String _oldImagesName = 'old_images';
}

/// Minimal [QueryExecutorUser] for the validation probe: it only opens the
/// snapshot copy to count item rows and never creates or migrates anything.
/// The probe file is deleted right after validation.
class _ProbeUser implements QueryExecutorUser {
  const _ProbeUser();

  @override
  int get schemaVersion => 0;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {
  }
}

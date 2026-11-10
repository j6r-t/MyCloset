import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Owns the on-disk file layout described in docs/backend.md section 2.2:
///
/// ```
/// - images/{item_id}/original.jpg
/// - images/{item_id}/cutout.png
/// - backups/closet_backup_(date).zip
/// - tmp/  drafts, cleared on cancel and app start
/// ```
///
/// Ordering rule from section 2.2: callers write draft files to [tmpDir],
/// save the database row only after committing files via
/// [commitDraftToItem], and delete orphan files on any failure.
class FileStorageService {
  /// Resolves the app documents directory. Injectable so tests can point the
  /// service at a temporary directory.
  final Future<Directory> Function() documentsDir;

  FileStorageService({Future<Directory> Function()? documentsDir})
      : documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  // ---------------------------------------------------------------- layout

  /// `images`, creating it if needed.
  Future<Directory> imagesRoot() async =>
      _ensureDir(_join((await documentsDir()).path, 'images'));

  /// `images/{itemId}`.
  Future<Directory> itemDir(int itemId) async => _ensureDir(
        _join((await imagesRoot()).path, itemId.toString()),
      );

  /// `backups`, creating it if needed.
  Future<Directory> backupsDir() async =>
      _ensureDir(_join((await documentsDir()).path, 'backups'));

  /// `tmp`, creating it if needed.
  Future<Directory> tmpDir() async =>
      _ensureDir(_join((await documentsDir()).path, 'tmp'));

  // ---------------------------------------------------------------- drafts

  /// Writes draft bytes into the tmp directory. Returns the written path.
  Future<String> saveDraft(Uint8List bytes, String fileName) async {
    final path = _join((await tmpDir()).path, fileName);
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Deletes everything under tmp. Called when a flow is cancelled and at
  /// app start so drafts never leak.
  Future<void> clearTmp() async {
    final dir = Directory(_join((await documentsDir()).path, 'tmp'));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Moves committed draft files into `images/{itemId}/`.
  ///
  /// When [draftCutoutPath] is null (segmentation fell back to the original
  /// photo, backend.md section 3.3), [CommittedItemFiles.cutoutPath] equals
  /// the committed original path - the schema requires a non-null cutout
  /// path and the UI uses the same image for both.
  ///
  /// Returns the final absolute paths to store in the database row.
  Future<CommittedItemFiles> commitDraftToItem(
    int itemId, {
    required String draftOriginalPath,
    String? draftCutoutPath,
  }) async {
    final dirPath = (await itemDir(itemId)).path;
    final original = _join(dirPath, 'original.jpg');
    await File(draftOriginalPath).rename(original);

    String cutout;
    if (draftCutoutPath != null) {
      cutout = _join(dirPath, 'cutout.png');
      await File(draftCutoutPath).rename(cutout);
    } else {
      cutout = original;
    }

    return CommittedItemFiles(originalPath: original, cutoutPath: cutout);
  }

  /// Deletes `images/{itemId}` entirely. Used when an item is deleted or
  /// when saving failed and the files would be orphaned.
  Future<void> deleteItemFiles(int itemId) async {
    final dir = Directory(_join((await imagesRoot()).path, itemId.toString()));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  // ---------------------------------------------------------------- helpers

  Directory _ensureDir(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _join(String base, String child) =>
      '$base${Platform.pathSeparator}$child';
}

/// Final file paths to store in the items row after a draft commit.
class CommittedItemFiles {
  final String originalPath;
  final String cutoutPath;

  const CommittedItemFiles({required this.originalPath, required this.cutoutPath});
}

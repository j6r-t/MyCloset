// App-wide state for the UI layer: a plain ChangeNotifier over the finished
// backend services (docs/backend.md section 1: "plain StatefulWidget +
// ChangeNotifier until it hurts").
//
// The UI never touches the database or the file system directly; everything
// goes through [AppState]. Async errors that escape a screen's own handling
// surface through the global zone handler in main.dart (backend.md section 7).

import 'dart:io';

// material.dart for ThemeMode (the app-level light/dark/system preference).
import 'package:flutter/material.dart';

import '../database/app_database.dart';
import '../models/enums.dart';
import '../models/item.dart';
import '../models/outfit.dart';
import '../services/backup_service.dart';
import '../services/file_storage_service.dart';
import '../services/identification_pipeline.dart';

/// Inherited access to the single [AppState].
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()!.notifier!;
}

/// Holds the wardrobe and outfits in memory, mirrors writes to the database
/// and image files, and notifies listening screens.
class AppState extends ChangeNotifier {
  AppDatabase _database;
  BackupService _backup;

  final FileStorageService storage;

  /// All items, newest first (wardrobe default sort).
  List<Item> items = [];

  /// All outfits, newest first.
  List<Outfit> outfits = [];

  /// outfitId -> its slot entries.
  final Map<int, List<OutfitEntry>> _outfitItems = {};

  /// The persisted app theme preference (Settings screen). Defaults to
  /// following the system until the user picks a mode; read from the
  /// database in [load].
  ThemeMode themeMode = ThemeMode.system;

  /// app_settings keys for the online identification API keys. The VALUES
  /// are read from the database only when an identification actually runs;
  /// the UI only ever sees the set/unset flags below. Keys are never logged
  /// and never leave app_settings.
  static const String serpApiKeySetting = 'identification_serpapi_key';
  static const String visionApiKeySetting = 'identification_vision_key';

  /// Set/unset flags for the Settings screen ("Set"/"Not set" captions).
  /// Kept as booleans precisely so the stored values never reach the UI.
  bool serpApiKeySet = false;
  bool visionApiKeySet = false;

  /// True once the first [load] finished (successfully or not).
  bool loaded = false;

  /// Last load error, if any, for quiet surfacing in the UI.
  Object? loadError;

  AppState({required AppDatabase database, required this.storage})
      : _database = database,
        _backup = BackupService(
          database: database,
          storage: storage,
        );

  /// Production wiring: real drift database and on-disk file layout.
  factory AppState.live() => AppState(
        database: AppDatabase.open(),
        storage: FileStorageService(),
      );

  AppDatabase get database => _database;
  BackupService get backup => _backup;

  // ---------------------------------------------------------------- lookups

  Item? itemById(int id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// Slot entries of one outfit. Empty map when the outfit has no rows
  /// (or was deleted mid-session).
  Map<OutfitSlot, int> slotsOf(int outfitId) {
    final map = <OutfitSlot, int>{};
    for (final entry in _outfitItems[outfitId] ?? const <OutfitEntry>[]) {
      map[entry.slot] = entry.itemId;
    }
    return map;
  }

  // ----------------------------------------------------------------- loading

  /// Clears leftover drafts (backend.md section 2.2: tmp is wiped on app
  /// start) and reads the wardrobe and outfits.
  ///
  /// Never throws: a failed load leaves the app usable with an empty state
  /// and records [loadError] (backend.md section 7 - the app never
  /// white-screens).
  Future<void> load() async {
    try {
      await storage.clearTmp();
      items = await _database.getAllItems();
      outfits = await _database.getAllOutfits();
      _outfitItems.clear();
      for (final entry in await _database.getAllOutfitItems()) {
        _outfitItems.putIfAbsent(entry.outfitId, () => []).add(entry);
      }
      loadError = null;
      // Theme preference: read separately so a settings-table problem never
      // masks a wardrobe that loaded fine.
      try {
        final stored = await _database.getSetting('theme_mode');
        themeMode = switch (stored) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      } catch (e) {
        debugPrint('AppState.load: theme preference unavailable: $e');
      }
      // Key set/unset flags (values are fetched only when a lookup runs).
      try {
        serpApiKeySet = _isSet(await _database.getSetting(serpApiKeySetting));
        visionApiKeySet = _isSet(await _database.getSetting(visionApiKeySetting));
      } catch (e) {
        debugPrint('AppState.load: identification keys unavailable: $e');
      }
    } catch (e) {
      loadError = e;
      debugPrint('AppState.load failed: $e');
    }
    loaded = true;
    notifyListeners();
  }

  // ------------------------------------------------------------------- items

  /// Saves a new item from the add-item flow (userFlow.md flow 2).
  ///
  /// The files are committed into `images/{id}/` right after the row insert
  /// reserves the id, then the row is updated with the final paths; if the
  /// commit fails the row is deleted again so no orphans remain (backend.md
  /// section 2.2 ordering rule).
  ///
  /// Returns the new item's id. Pass null for [draftCutoutPath] when
  /// segmentation fell back to the original photo (backend.md section 3.3).
  Future<int> saveDraftItem({
    required String name,
    required Category category,
    String? subtype,
    String? brand,
    double? price,
    String? size,
    LayerType? layerType,
    Condition? condition,
    Season season = Season.all,
    String? fabric,
    String? notes,
    required String colorPrimaryHex,
    String? colorPrimaryName,
    String? colorSecondaryHex,
    String? colorSecondaryName,
    required String draftOriginalPath,
    String? draftCutoutPath,
  }) async {
    final id = await _database.insertItem(
      name: name,
      category: category,
      subtype: subtype,
      brand: brand,
      price: price,
      size: size,
      layerType: layerType,
      condition: condition,
      season: season,
      fabric: fabric,
      notes: notes,
      colorPrimaryHex: colorPrimaryHex,
      colorPrimaryName: colorPrimaryName,
      colorSecondaryHex: colorSecondaryHex,
      colorSecondaryName: colorSecondaryName,
      // Placeholder paths, replaced below once the id exists.
      imagePath: draftOriginalPath,
      cutoutPath: draftCutoutPath ?? draftOriginalPath,
    );
    // Name is optional in the UI; default it to "Piece #<id>" once the id
    // exists (design.md section 6.4).
    final effectiveName = name.trim().isEmpty ? 'Piece #$id' : name.trim();
    try {
      final committed = await storage.commitDraftToItem(
        id,
        draftOriginalPath: draftOriginalPath,
        draftCutoutPath: draftCutoutPath,
      );
      await _database.updateItem(
        Item(
          id: id,
          name: effectiveName,
          category: category,
          subtype: subtype,
          brand: brand,
          price: price,
          size: size,
          layerType: layerType,
          condition: condition,
          season: season,
          fabric: fabric,
          notes: notes,
          colorPrimaryHex: colorPrimaryHex,
          colorPrimaryName: colorPrimaryName,
          colorSecondaryHex: colorSecondaryHex,
          colorSecondaryName: colorSecondaryName,
          imagePath: committed.originalPath,
          cutoutPath: committed.cutoutPath,
          createdAt: DateTime.now(),
        ),
      );
    } catch (e) {
      await _database.deleteItem(id);
      await storage.deleteItemFiles(id);
      rethrow;
    }
    await load();
    return id;
  }

  /// Rewrites an existing item's editable fields (edit flow).
  Future<void> updateItem(Item item) async {
    await _database.updateItem(item);
    await load();
  }

  /// Deletes an item, its image files, and its outfit slot rows (the slots
  /// stay in the outfits as "missing item" per userFlow.md edge behaviors).
  Future<void> deleteItem(int id) async {
    await _database.deleteItem(id);
    await storage.deleteItemFiles(id);
    await load();
  }

  // ----------------------------------------------------------------- outfits

  /// Creates an outfit with the given slot assignment. The UI enforces the
  /// dress xor (top + bottom) invariant before calling; the database layer
  /// enforces it again on write.
  Future<int> createOutfit(
    String name,
    Map<OutfitSlot, Item> slots, {
    DateTime? createdAt,
  }) async {
    final id = await _database.insertOutfit(name, createdAt: createdAt);
    for (final entry in slots.entries) {
      await _database.setOutfitSlot(id, entry.value.id, entry.key);
    }
    await load();
    return id;
  }

  /// Rewrites an existing outfit's name and slots. The database layer has no
  /// update API, so this recreates the row keeping its id semantics simple:
  /// delete + reinsert with the original creation date.
  Future<void> replaceOutfit(
    int outfitId,
    String name,
    Map<OutfitSlot, Item> slots,
  ) async {
    final existing = await _database.getOutfit(outfitId);
    await _database.deleteOutfit(outfitId);
    await createOutfit(
      name,
      slots,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
  }

  Future<void> deleteOutfit(int outfitId) async {
    await _database.deleteOutfit(outfitId);
    await load();
  }

  /// Renames an outfit in place (keeps its id and creation date).
  Future<void> renameOutfit(int outfitId, String name) async {
    await _database.renameOutfit(outfitId, name);
    await load();
  }

  /// Empties one slot of an outfit (the outfit detail's per-row delete;
  /// the emptied slot renders as a dashed placeholder per userFlow.md edge
  /// behaviors).
  Future<void> removeOutfitSlot(int outfitId, OutfitSlot slot) async {
    await _database.removeOutfitSlot(outfitId, slot);
    await load();
  }

  // ------------------------------------------------------------ appearance

  /// Persists the app theme preference and applies it immediately.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    try {
      await _database.setSetting('theme_mode', mode.name);
    } catch (e) {
      // The choice stays applied for this session even if the write fails.
      debugPrint('AppState.setThemeMode: could not persist: $e');
    }
  }

  // ------------------------------------------------- online identification

  /// Reads one stored API key straight from app_settings (null when unset
  /// or blank). Values are never exposed to widgets - only the pipeline and
  /// its services see them.
  Future<String?> getSerpApiKey() async =>
      _keyOrNull(await _database.getSetting(serpApiKeySetting));

  Future<String?> getVisionApiKey() async =>
      _keyOrNull(await _database.getSetting(visionApiKeySetting));

  static String? _keyOrNull(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;

  /// Persists the SerpAPI key (or clears it when [value] trims to empty)
  /// and refreshes the set/unset flag. The value is never logged.
  Future<void> setSerpApiKey(String value) =>
      _setApiKey(serpApiKeySetting, value, (set) => serpApiKeySet = set);

  /// Persists the Cloud Vision key (or clears it when [value] trims to
  /// empty) and refreshes the set/unset flag. The value is never logged.
  Future<void> setVisionApiKey(String value) =>
      _setApiKey(visionApiKeySetting, value, (set) => visionApiKeySet = set);

  Future<void> _setApiKey(
    String settingKey,
    String value,
    void Function(bool set) applyFlag,
  ) async {
    final trimmed = value.trim();
    await _database.setSetting(settingKey, trimmed);
    applyFlag(trimmed.isNotEmpty);
    notifyListeners();
  }

  static bool _isSet(String? value) => value != null && value.trim().isNotEmpty;

  /// Runs the online identification pipeline (the app's only networked
  /// feature - strictly opt-in, triggered from the details form). Reads the
  /// keys from app_settings on demand; they never leave this call except
  /// into the service requests.
  Future<IdentificationResult> runIdentification({
    required String imagePath,
    String? categoryLabel,
    String? subtype,
    String? brand,
  }) async {
    String? serpKey;
    String? visionKey;
    try {
      serpKey = await getSerpApiKey();
      visionKey = await getVisionApiKey();
    } catch (e) {
      debugPrint('AppState.runIdentification: keys unreadable: $e');
    }
    return IdentificationPipeline().identify(
      imagePath: imagePath,
      categoryLabel: categoryLabel,
      subtype: subtype,
      brand: brand,
      serpApiKey: serpKey,
      visionApiKey: visionKey,
    );
  }

  // ----------------------------------------------------------- backup/restore

  /// Creates a backup zip and returns its path.
  Future<String> createBackup() => _backup.createBackup();

  /// Opens the share sheet for a backup zip.
  Future<void> shareBackup(String zipPath) => _backup.shareBackup(zipPath);

  /// Lists the zips previously exported into the app's backups directory,
  /// newest first. Restore candidates for the settings screen.
  Future<List<String>> listBackups() async {
    final dir = await storage.backupsDir();
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.zip')) files.add(entity);
    }
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files.map((f) => f.path).toList();
  }

  /// Validates a backup zip without touching live data.
  Future<RestorePreview> validateBackup(String zipPath) =>
      _backup.validateBackup(zipPath);

  /// Restores a backup. The service closes the live database during the
  /// swap, so this rebuilds the database connection afterwards and reloads.
  Future<void> restoreBackup(String zipPath) async {
    await _backup.restoreBackup(zipPath);
    _database = AppDatabase.open();
    _backup = BackupService(database: _database, storage: storage);
    await load();
  }
}

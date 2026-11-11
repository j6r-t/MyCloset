import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Regression test for the "Could not resolve native function
/// `sqlite3_temp_directory`" crash seen on Android (Settings > save API key,
/// November 2026).
///
/// drift_flutter's connection setup used to assign `sqlite3.tempDirectory`
/// globally; that assignment reads the native data symbol
/// `sqlite3_temp_directory`, which is exactly the symbol missing from some
/// Android SQLite builds. The app no longer performs that assignment (see
/// AppDatabase.open), but this test guards the other half of the contract:
/// the SQLite library that native assets resolves for this project must
/// itself expose the symbol, i.e. a set/get roundtrip of tempDirectory must
/// work instead of throwing an ArgumentError.
///
/// Host-only caveat: this runs against the Windows native-assets DLL, so it
/// proves the resolved library is complete on the dev machine. It cannot
/// prove what the arm64 .so exports on a device; that was verified by
/// inspecting the built APK (llvm-nm -D on lib/arm64-v8a/libsqlite3.so).
void main() {
  test('sqlite3.tempDirectory set/get roundtrip resolves the native symbol',
      () {
    final original = sqlite3.tempDirectory;
    try {
      sqlite3.tempDirectory = null;
      expect(sqlite3.tempDirectory, isNull);
      sqlite3.tempDirectory = original;
      expect(sqlite3.tempDirectory, original);
    } finally {
      // Restore whatever the process had so other tests are unaffected.
      sqlite3.tempDirectory = original;
    }
  });
}

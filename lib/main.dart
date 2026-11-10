import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/app_shell.dart';
import 'ui/app_state.dart';
import 'ui/theme.dart';

/// App entry point.
///
/// A global zone handler catches any unhandled async error, logs it and
/// shows a non-blocking snackbar - the app never white-screens
/// (docs/backend.md section 7).
void main() {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Errors from the framework side (build/layout) also surface quietly.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('FlutterError: ${details.exception}');
        _showGlobalError(details.exception.toString());
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('Unhandled platform error: $error\n$stack');
        _showGlobalError(error.toString());
        return true;
      };

      // Android-only, portrait (project handoff constraints).
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);

      final state = AppState.live();
      await state.load();

      runApp(MyClosetApp(state: state));
    },
    (error, stack) {
      debugPrint('Unhandled zone error: $error\n$stack');
      _showGlobalError(error.toString());
    },
  );
}

/// Global scaffold messenger key so the zone handler can post a snackbar
/// from anywhere, even outside the widget tree.
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void _showGlobalError(String message) {
  // Do not rebuild the tree from the error path; post to the messenger if
  // the app is up, otherwise just log (already done by the caller).
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;
  try {
    messenger.showSnackBar(
      SnackBar(content: Text('Something went wrong: $message')),
    );
  } catch (_) {
    // Snackbars during teardown can throw; never escalate an error handler.
  }
}

class MyClosetApp extends StatelessWidget {
  final AppState state;

  const MyClosetApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: state,
      child: Builder(
        builder: (scopeContext) {
          // Depend on the AppStateScope notifier so a theme-mode change in
          // Settings rebuilds the MaterialApp immediately.
          final themeMode = AppStateScope.of(scopeContext).themeMode;
          return MaterialApp(
            title: 'MyCloset',
            scaffoldMessengerKey: scaffoldMessengerKey,
            // Light and dark share the Fitted-minimal identity; the user's
            // choice (System / Light / Dark) persists in app_settings.
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: themeMode,
            home: const AppShell(),
          );
        },
      ),
    );
  }
}

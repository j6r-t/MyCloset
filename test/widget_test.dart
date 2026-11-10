// Smoke test: the app builds and shows the wardrobe dashboard tab root.
//
// The production entry point opens the real drift database, which needs the
// path_provider plugin and is unavailable under the test binding; the load
// failure is handled inside AppState (it degrades to an empty wardrobe), so
// this test simply pumps MyClosetApp with a live-shaped state and expects
// the empty-state UI.
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/main.dart';
import 'package:my_closet/screens/wardrobe_screen.dart';
import 'package:my_closet/ui/app_shell.dart';
import 'package:my_closet/ui/app_state.dart';

void main() {
  testWidgets('MyCloset builds and shows the wardrobe tab root',
      (WidgetTester tester) async {
    final state = AppState.live();
    await tester.pumpWidget(MyClosetApp(state: state));
    // Let the (failing, plugin-less) load and the empty state settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Your closet is waiting.'), findsOneWidget);
    expect(find.byType(WardrobeScreen), findsOneWidget);
    expect(find.byType(AppShell), findsOneWidget);
    // The four floating-nav tabs and the add FAB are all present.
    expect(find.text('Wardrobe'), findsOneWidget);
    expect(find.text('Outfits'), findsOneWidget);
    expect(find.text('Suggest'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}

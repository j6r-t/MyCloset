// Radial named-color picker tests: the wheel renders every curated color as
// an OPAQUE swatch (guards the alpha-0 empty-swatch bug), a tap commits the
// tapped name, a drag shows the offset loupe with the hovered color and
// commits it on release, and the current selection is pre-marked in both
// themes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/data/named_colors.dart';
import 'package:my_closet/ui/theme.dart';
import 'package:my_closet/widgets/named_color_picker.dart';

NamedColor _named(String name) =>
    kNamedColors.firstWhere((n) => n.name == name);

BoxDecoration _decorationOf(WidgetTester tester, Key key) {
  final container = tester.widget<Container>(find.byKey(key));
  return container.decoration! as BoxDecoration;
}

/// Opens the picker sheet from a themed harness; the returned completer is
/// completed with whatever the picker pops with.
Future<Completer<NamedColor?>> _openPicker(
  WidgetTester tester, {
  NamedColor? current,
  Brightness brightness = Brightness.light,
}) async {
  final completer = Completer<NamedColor?>();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(brightness),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                final result =
                    await showNamedColorPicker(context, current: current);
                completer.complete(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return completer;
}

void main() {
  testWidgets(
      'wheel renders every curated color as an opaque swatch (light theme)',
      (tester) async {
    await _openPicker(tester);

    // All 36 colors present, split ring vs center cluster.
    expect(find.byType(Container), findsWidgets);
    for (final named in kNamedColors) {
      expect(
        find.byKey(Key('swatch-${named.name}')),
        findsOneWidget,
        reason: '${named.name} missing from the wheel',
      );
    }
    expect(kWheelChromatic.length + kWheelNeutrals.length, kNamedColors.length);

    // The old bug: parsing '#RRGGBB' without the alpha byte gave 0x00RRGGBB,
    // fully transparent swatches (empty cards). Both a dark and a light
    // swatch must paint opaque with their exact stored value.
    expect(
      _decorationOf(tester, const Key('swatch-navy')).color,
      const Color(0xFF1C2B4A),
    );
    expect(
      _decorationOf(tester, const Key('swatch-white')).color,
      const Color(0xFFFAFAFA),
    );
  });

  testWidgets('swatches stay opaque on the dark theme', (tester) async {
    await _openPicker(tester, brightness: Brightness.dark);
    expect(
      _decorationOf(tester, const Key('swatch-burgundy')).color,
      const Color(0xFF800020),
    );
  });

  testWidgets('current selection is pre-marked in the center disc',
      (tester) async {
    await _openPicker(tester, current: _named('navy'));
    expect(
      _decorationOf(tester, const Key('center-disc')).color,
      const Color(0xFF1C2B4A),
    );
  });

  testWidgets('tap on a swatch commits that named color', (tester) async {
    final completer = await _openPicker(tester);
    await tester.tap(find.byKey(const Key('swatch-scarlet')));
    await tester.pumpAndSettle();
    expect(await completer.future, _named('scarlet'));
  });

  testWidgets('drag shows the loupe with the hovered color and commits on '
      'release', (tester) async {
    final completer = await _openPicker(tester);

    final start = tester.getCenter(find.byKey(const Key('swatch-navy')));
    final target = tester.getCenter(find.byKey(const Key('swatch-sky blue')));

    final gesture = await tester.startGesture(start);
    // Move past the touch slop so the drag starts while staying on navy.
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    // Loupe is up, offset above the finger, naming the hovered color.
    expect(find.byKey(const Key('color-loupe')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('color-loupe')),
        matching: find.text('navy'),
      ),
      findsOneWidget,
    );

    // Drag to another swatch; the loupe follows the hover.
    await gesture.moveBy(target - start - const Offset(0, 20));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('color-loupe')),
        matching: find.text('sky blue'),
      ),
      findsOneWidget,
    );

    // Release commits the color under the finger and dismisses the loupe.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('color-loupe')), findsNothing);
    expect(await completer.future, _named('sky blue'));
  });

  testWidgets('close button cancels with null (cancel semantics preserved)',
      (tester) async {
    final completer = await _openPicker(tester);
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pumpAndSettle();
    expect(await completer.future, isNull);
  });
}

// Continuous HSV-wheel named-color picker tests. Semantics unchanged from
// the old swatch-grid wheel - the picker opens, a tap commits the tapped
// name, a drag shows the offset loupe naming the hovered color and commits
// it on release, the current selection is pre-marked in both themes, close
// cancels with null. The internals moved from 36 discrete swatch Containers
// to a painted hue/saturation surface, so the old opaque-swatch-container
// assertions are replaced by geometry + snap wiring assertions (the wheel
// maps tapped hue/saturation to the nearest curated name via
// snapToNamedColor), and the pre-marked center disc by the selection ring.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/data/named_colors.dart';
import 'package:my_closet/services/color_math.dart';
import 'package:my_closet/ui/theme.dart';
import 'package:my_closet/widgets/named_color_picker.dart';

NamedColor _named(String name) =>
    kNamedColors.firstWhere((n) => n.name == name);

/// The curated name the picker snaps a wheel point (hue/saturation at
/// brightness [value]) to - the same mapping the widget applies, built
/// here from the picker's public geometry helper.
NamedColor _expectedAt(double hue, double saturation, [double? value]) {
  final color = HSVColor.fromAHSV(
    1.0,
    hue,
    saturation,
    value ?? kWheelMaxValue,
  ).toColor();
  return snapToNamedColor(rgbToHex(
    (color.r * 255).round(),
    (color.g * 255).round(),
    (color.b * 255).round(),
  ))!;
}

/// Absolute coordinates of a wheel point for hue/saturation.
Offset _wheelPoint(WidgetTester tester, double hue, double saturation) {
  final topLeft = tester.getTopLeft(find.byKey(const Key('color-wheel')));
  final size = tester.getSize(find.byKey(const Key('color-wheel'))).width;
  return topLeft + wheelPointForHsv(hue, saturation, size);
}

/// Absolute coordinates of the selection ring's center for hue/saturation
/// (17 = the picker's marker inset, keeping the ring inside the rim).
Offset _markerPoint(WidgetTester tester, double hue, double saturation) {
  final topLeft = tester.getTopLeft(find.byKey(const Key('color-wheel')));
  final size = tester.getSize(find.byKey(const Key('color-wheel'))).width;
  return topLeft +
      wheelPointForHsv(hue, saturation, size, rimInset: 17);
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

/// Starts a wheel drag at hue/saturation and pushes it past the touch slop.
Future<TestGesture> _startDrag(
  WidgetTester tester,
  double hue,
  double saturation,
) async {
  final gesture = await tester.startGesture(_wheelPoint(tester, hue, saturation));
  await gesture.moveBy(const Offset(0, 20));
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('picker opens with the continuous wheel', (tester) async {
    await _openPicker(tester);

    expect(find.byKey(const Key('color-wheel')), findsOneWidget);
    expect(find.text('Color'), findsOneWidget);
    // No current selection and no drag: nothing is marked, the readout
    // invites a pick.
    expect(find.byKey(const Key('selection-marker')), findsNothing);
    expect(find.text('Pick a color'), findsOneWidget);
    expect(find.byKey(const Key('value-slider')), findsOneWidget);
  });

  testWidgets('current selection is pre-marked at its hue and saturation',
      (tester) async {
    await _openPicker(tester, current: _named('navy'));

    expect(find.byKey(const Key('selection-marker')), findsOneWidget);
    final navy = HSVColor.fromColor(const Color(0xFF1C2B4A));
    final expected = _markerPoint(tester, navy.hue, navy.saturation);
    final actual = tester.getCenter(find.byKey(const Key('selection-marker')));
    expect((actual - expected).distance, lessThan(4.0));
    // And the readout names it before anything is touched.
    expect(find.text('navy'), findsOneWidget);
  });

  testWidgets('tap on the wheel commits the nearest curated name',
      (tester) async {
    final completer = await _openPicker(tester);

    // A saturated red near the rim snaps to scarlet.
    await tester.tapAt(_wheelPoint(tester, 0, 0.95));
    await tester.pumpAndSettle();
    expect(await completer.future, _named('scarlet'));
  });

  testWidgets('tap on the white center commits white', (tester) async {
    final completer = await _openPicker(tester);

    await tester.tapAt(_wheelPoint(tester, 0, 0));
    await tester.pumpAndSettle();
    expect(await completer.future, _named('white'));
  });

  testWidgets('drag shows the loupe with the hovered color and commits on '
      'release', (tester) async {
    final completer = await _openPicker(tester);

    final startLocal = wheelPointForHsv(210, 0.9, 380);
    final gesture = await _startDrag(tester, 210, 0.9);

    // The loupe is up, offset above the finger, naming the hovered color.
    final afterSlop = wheelHsvAt(startLocal + const Offset(0, 20), 380);
    final startName = _expectedAt(afterSlop.hue, afterSlop.saturation).name;
    expect(find.byKey(const Key('color-loupe')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('color-loupe')),
        matching: find.text(startName),
      ),
      findsOneWidget,
    );

    // Drag across the wheel to another hue; the loupe follows the hover.
    final targetLocal = wheelPointForHsv(40, 0.9, 380);
    await gesture.moveBy(targetLocal - (startLocal + const Offset(0, 20)));
    await tester.pump();
    final targetHsv = wheelHsvAt(targetLocal, 380);
    final targetName = _expectedAt(targetHsv.hue, targetHsv.saturation).name;
    expect(targetName, isNot(startName));
    expect(
      find.descendant(
        of: find.byKey(const Key('color-loupe')),
        matching: find.text(targetName),
      ),
      findsOneWidget,
    );

    // Release commits the color under the finger and dismisses the loupe.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('color-loupe')), findsNothing);
    expect(await completer.future, _expectedAt(targetHsv.hue, targetHsv.saturation));
  });

  testWidgets('the loupe is a circle with a fine white border and a soft '
      'drop shadow', (tester) async {
    await _openPicker(tester);
    final gesture = await _startDrag(tester, 210, 0.9);

    final container =
        tester.widget<Container>(find.byKey(const Key('loupe-disc')));
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(
      (decoration.border! as Border).top.color,
      const Color(0xFFFFFFFF),
    );
    expect(decoration.boxShadow, isNotEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('color-loupe')), findsNothing);
  });

  testWidgets('brightness slider lets a tap reach the dark names',
      (tester) async {
    final completer = await _openPicker(tester);

    // Pull the slider to its dark end, then tap a saturated blue.
    await tester.drag(find.byKey(const Key('value-slider')),
        const Offset(-600, 0));
    await tester.pump();
    await tester.tapAt(_wheelPoint(tester, 222, 0.85));
    await tester.pumpAndSettle();

    final dark = _expectedAt(222, 0.85, kWheelMinValue);
    expect(await completer.future, dark);
    // Brightness mattered: the same hue/saturation at full brightness is a
    // different curated name.
    expect(_expectedAt(222, 0.85), isNot(dark));
  });

  testWidgets('wheel, marker and loupe work on the dark theme',
      (tester) async {
    await _openPicker(tester,
        current: _named('navy'), brightness: Brightness.dark);

    expect(find.byKey(const Key('selection-marker')), findsOneWidget);
    expect(find.text('navy'), findsOneWidget);

    final gesture = await _startDrag(tester, 210, 0.9);
    expect(find.byKey(const Key('color-loupe')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('color-loupe')), findsNothing);
  });

  testWidgets('close button cancels with null (cancel semantics preserved)',
      (tester) async {
    final completer = await _openPicker(tester);
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pumpAndSettle();
    expect(await completer.future, isNull);
  });
}

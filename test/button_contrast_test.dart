// Contrast pairing tests (design.md section 1): every ink-filled surface
// renders its label in white. Guards against the black-on-black bug where a
// label's explicit TextStyle overrides the button theme's foreground color.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/screens/cutout_review_screen.dart';
import 'package:my_closet/ui/theme.dart';

Color? _labelColor(WidgetTester tester, String label) {
  final RenderParagraph paragraph = tester.renderObject(find.text(label));
  return paragraph.text.style?.color;
}

void main() {
  testWidgets('Theme FilledButton labels: enabled white on ink, disabled '
      'ink-secondary on tile', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(onPressed: () {}, child: const Text('Save')),
                FilledButton(onPressed: null, child: const Text('Disabled')),
              ],
            ),
          ),
        ),
      ),
    );
    // Enabled ink fill pairs with white content (onPrimary).
    expect(_labelColor(tester, 'Save'), AppColors.light.bg);
    // Disabled tile fill pairs with ink-secondary.
    expect(_labelColor(tester, 'Disabled'), AppColors.light.inkSecondary);
  });

  testWidgets('Cutout review: Continue (ink fill) is white, Retake '
      '(outlined) is ink', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        // No draftCutoutPath: the no-cutout fallback, so the screen builds
        // without a decoder or file system and the action row is real.
        home: const Scaffold(
          body: CutoutReviewScreen(draftOriginalPath: 'unused.jpg'),
        ),
      ),
    );
    expect(_labelColor(tester, 'Continue'), AppColors.light.bg);
    expect(_labelColor(tester, 'Retake'), AppColors.light.ink);
  });
}

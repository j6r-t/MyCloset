import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// One eraser brush control row (design.md sections 1-2: minimal chrome -
/// a small icon, a hairline-track slider, and a caption value). Used for
/// brush thickness and brush opacity in the cutout review eraser toolbar.
///
/// The row reports drag start/end separately ([onChangeStart] /
/// [onChangeEnd]) so the canvas can show the live size/opacity indicator
/// ring while the control is being dragged.
class BrushControlRow extends StatelessWidget {
  /// Small leading glyph (Material Symbols Outlined, design.md section 4).
  final IconData icon;

  /// Semantic label (also the Slider tooltip semantics).
  final String label;

  final double value;
  final double min;
  final double max;

  /// Stepped values keep the caption clean (e.g. whole pixels, whole %).
  final int divisions;

  /// Right-aligned value caption, e.g. "40" or "40%".
  final String caption;

  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  const BrushControlRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.caption,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 18, color: c.inkSecondary),
          const SizedBox(width: Spacing.s),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: c.ink,
                inactiveTrackColor: c.hairline,
                thumbColor: c.ink,
                overlayColor: Colors.transparent,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: caption,
                onChanged: onChanged,
                onChangeStart: onChangeStart == null
                    ? null
                    : (_) => onChangeStart!(),
                onChangeEnd: onChangeEnd == null ? null : (_) => onChangeEnd!(),
              ),
            ),
          ),
          const SizedBox(width: Spacing.s),
          SizedBox(
            width: 40,
            child: Text(
              caption,
              textAlign: TextAlign.right,
              style: AppText.caption(context),
            ),
          ),
        ],
      ),
    );
  }
}

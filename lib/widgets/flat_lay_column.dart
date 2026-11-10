import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../ui/theme.dart';
import 'cutout_image.dart';

/// Vertical flat-lay column (design.md sections 6.6-6.8): every garment its
/// own frameless cutout stacked top to bottom with small 6px gaps, never
/// overlapping, directly on the background - no card frame.
///
/// The shared renderer for the outfits gallery, the outfit builder's live
/// preview, and the suggestion cards. Slots are ordered dress, then
/// top + bottom, then shoes, then outerwear and accessory appended.
///
/// An outfit whose core (dress, or top and bottom) was deleted renders a
/// dashed empty slot (userFlow.md edge behaviors: "missing item").
class FlatLayColumn extends StatelessWidget {
  /// Items in display order. Missing slots simply contribute nothing.
  final List<Item> items;

  /// Shows a dashed placeholder slot for the missing garment core.
  final bool showMissing;

  const FlatLayColumn({
    super.key,
    required this.items,
    this.showMissing = false,
  });

  /// Orders an outfit's items for the column: dress first, then top and
  /// bottom, then shoes, then outerwear and accessory (design.md section 6.6).
  static List<Item> ordered(Map<OutfitSlot, Item> slots) {
    const order = [
      OutfitSlot.dress,
      OutfitSlot.top,
      OutfitSlot.bottom,
      OutfitSlot.shoes,
      OutfitSlot.outerwear,
      OutfitSlot.accessory,
    ];
    return [
      for (final slot in order)
        if (slots[slot] != null) slots[slot]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final visible = items.where((i) => i.cutoutPath.isNotEmpty).toList();

    if (visible.isEmpty && !showMissing) {
      return Center(
        child: Icon(AppIcons.hanger, size: 28, color: c.hairline),
      );
    }

    return Column(
      children: [
        if (showMissing)
          const Expanded(child: _MissingSlot()),
        for (final item in visible)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: CutoutImage(path: item.cutoutPath),
            ),
          ),
      ],
    );
  }
}

/// The dashed empty slot shown where a deleted item used to be
/// (userFlow.md edge behaviors).
class _MissingSlot extends StatelessWidget {
  const _MissingSlot();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: CustomPaint(
        painter: _DashedSlotPainter(color: c.hairline),
        child: Center(
          child: Icon(AppIcons.hanger, size: 20, color: c.hairline),
        ),
      ),
    );
  }
}

class _DashedSlotPainter extends CustomPainter {
  final Color color;

  _DashedSlotPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(8),
        ),
      );

    const dash = 4.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = distance + dash > metric.length
            ? metric.length
            : distance + dash;
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSlotPainter old) => old.color != color;
}

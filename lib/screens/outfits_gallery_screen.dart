import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/flat_lay_column.dart';
import 'outfit_builder_screen.dart';
import 'outfit_detail_screen.dart';

/// Screen 6 - Outfits (tab root, design.md section 6.6): 2-column grid, the
/// first tile "Create Fit" (dashed), each outfit rendered as a vertical
/// flat-lay column - frameless cutouts stacked top to bottom, never
/// overlapping - with the name caption and date below.
class OutfitsGalleryScreen extends StatelessWidget {
  const OutfitsGalleryScreen({super.key});

  /// An outfit missing its dress / top+bottom core (deleted items) shows a
  /// dashed empty slot (userFlow.md edge behaviors).
  static bool isIncomplete(Map<OutfitSlot, int> slots) =>
      !(slots.containsKey(OutfitSlot.dress) ||
          (slots.containsKey(OutfitSlot.top) &&
              slots.containsKey(OutfitSlot.bottom)));

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return SafeArea(
      bottom: false,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab-root title (no back button; the bottom pill owns navigation).
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.gutter,
            Spacing.m,
            Spacing.gutter,
            0,
          ),
          child: Text('Outfits', style: AppText.title(context)),
        ),
        Expanded(
          child: state.outfits.isEmpty
              ? EmptyState(
                  statement: 'No outfits yet.',
                  sub: 'Combine pieces, or start from a suggestion.',
                  actionLabel: 'Create Fit',
                  onAction: () => Navigator.of(context).push(
                    appRoute(const OutfitBuilderScreen()),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.gutter,
                    Spacing.m,
                    Spacing.gutter,
                    148,
                  ),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: Spacing.section,
                    mainAxisSpacing: Spacing.section,
                    childAspectRatio: 0.62,
                  ),
                  itemCount: state.outfits.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) return const _CreateFitTile();
                    final outfit = state.outfits[index - 1];
                    final slots = state.slotsOf(outfit.id);
                    final slotItems = <OutfitSlot, Item>{};
                    for (final entry in slots.entries) {
                      final item = state.itemById(entry.value);
                      if (item != null) slotItems[entry.key] = item;
                    }
                    return _OutfitTile(
                      name: outfit.name,
                      date: _formattedDate(outfit.createdAt),
                      items: FlatLayColumn.ordered(slotItems),
                      incomplete: isIncomplete(slots),
                      // Tap opens the outfit detail (name, flat lay,
                      // components); edit and delete live there now.
                      onTap: () => Navigator.of(context).push(
                        appRoute(
                          OutfitDetailScreen(outfitId: outfit.id),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
      ),
    );
  }
}

/// The "Create Fit" first tile (design.md section 6.6): plus icon and label
/// centered on a hairline-dashed square.
class _CreateFitTile extends StatelessWidget {
  const _CreateFitTile();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        appRoute(const OutfitBuilderScreen()),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: c.tile,
          borderRadius: BorderRadius.circular(16),
        ),
        child: CustomPaint(
          painter: _DashedTilePainter(color: c.hairline),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.add, size: 24, color: c.ink),
                const SizedBox(height: 4),
                Text('Create Fit', style: AppText.button(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One outfit cell: the vertical flat-lay column floating directly on the
/// background (no card frame), name caption and date below.
class _OutfitTile extends StatelessWidget {
  final String name;
  final String date;
  final List<Item> items;
  final bool incomplete;
  final VoidCallback onTap;

  const _OutfitTile({
    required this.name,
    required this.date,
    required this.items,
    required this.incomplete,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.s),
              child: FlatLayColumn(items: items, showMissing: incomplete),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label(context),
          ),
          const SizedBox(height: 2),
          Text(date, style: AppText.caption(context)),
        ],
      ),
    );
  }
}

class _DashedTilePainter extends CustomPainter {
  final Color color;

  _DashedTilePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
          Radius.circular(16),
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
  bool shouldRepaint(_DashedTilePainter old) => old.color != color;
}

String _formattedDate(DateTime date) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

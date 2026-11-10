import 'dart:async';

import 'package:flutter/material.dart';

import '../data/named_colors.dart';
import '../models/enums.dart';
import '../models/item.dart';
import '../ui/app_shell.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/filter_chip.dart';
import '../widgets/item_tile.dart';
import 'capture_screen.dart';
import 'item_detail_screen.dart';
import 'details_form_screen.dart';

/// Screen 1 - Wardrobe (home dashboard, design.md section 6.1): the total
/// wardrobe value as the headline, the category bar chart, sticky filter
/// pills (Category / Type / Color / Season, multi-select sheets), then the
/// 3-column seamless grid - cutouts floating plain, no labels; the first
/// tile is "+ Add Piece"; long-press opens Edit / Delete.
class WardrobeScreen extends StatefulWidget {
  const WardrobeScreen({super.key});

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen> {
  final Set<Category> _categories = {};
  final Set<String> _types = {};
  final Set<String> _colors = {};
  final Set<Season> _seasons = {};

  /// Just-saved item for the 1s border fade (flow 2, step 5). Fed by the
  /// shell's FAB through [newPieceHighlight].
  int? _highlightItemId;
  Timer? _highlightClear;

  @override
  void initState() {
    super.initState();
    newPieceHighlight.addListener(_onNewPiece);
  }

  @override
  void dispose() {
    newPieceHighlight.removeListener(_onNewPiece);
    _highlightClear?.cancel();
    super.dispose();
  }

  void _onNewPiece() {
    if (!mounted || newPieceHighlight.value == null) return;
    setState(() => _highlightItemId = newPieceHighlight.value);
    _highlightClear?.cancel();
    _highlightClear = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _highlightItemId = null);
    });
  }

  bool get _hasActiveFilters =>
      _categories.isNotEmpty ||
      _types.isNotEmpty ||
      _colors.isNotEmpty ||
      _seasons.isNotEmpty;

  void _clearFilters() {
    setState(() {
      _categories.clear();
      _types.clear();
      _colors.clear();
      _seasons.clear();
    });
  }

  List<Item> _filtered(List<Item> all) {
    return all.where((item) {
      if (_categories.isNotEmpty && !_categories.contains(item.category)) {
        return false;
      }
      if (_types.isNotEmpty && !_types.contains(item.subtype ?? '')) {
        return false;
      }
      if (_colors.isNotEmpty &&
          !_colors.contains(item.colorPrimaryName) &&
          !_colors.contains(item.colorSecondaryName)) {
        return false;
      }
      if (_seasons.isNotEmpty &&
          item.season != Season.all &&
          !_seasons.contains(item.season)) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<void> _startAddFlow() async {
    final newId = await Navigator.of(
      context,
    ).push<int>(appRoute(const CaptureScreen()));
    if (newId != null && mounted) {
      setState(() => _highlightItemId = newId);
      _highlightClear?.cancel();
      _highlightClear = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _highlightItemId = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final items = state.items;

    if (items.isEmpty) {
      return SafeArea(
        bottom: false,
        child: EmptyState(
          statement: 'Your closet is waiting.',
          sub: 'A plain background and good light are all it takes.',
          actionLabel: 'Add your first piece',
          onAction: _startAddFlow,
        ),
      );
    }

    final filtered = _filtered(items);

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: Spacing.s)),
          SliverToBoxAdapter(child: _header(context, items)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _FilterHeaderDelegate(
              child: _filterBar(context, filtered.length),
            ),
          ),
          if (filtered.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                statement: 'Nothing matches.',
                sub: 'Try widening the filters.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(0, Spacing.s, 0, 148),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: Spacing.gridGap,
                  mainAxisSpacing: Spacing.gridGap,
                  childAspectRatio: 0.75,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index == 0) return _AddPieceTile(onTap: _startAddFlow);
                  final item = filtered[index - 1];
                  return ItemTile(
                    item: item,
                    highlight: item.id == _highlightItemId,
                    onTap: () async {
                      await Navigator.of(
                        context,
                      ).push(appRoute(ItemDetailScreen(item: item)));
                    },
                    onLongPress: () => _showTileActions(item),
                  );
                }, childCount: filtered.length + 1),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- header

  /// The value headline and the category bar chart (design.md section 6.1).
  Widget _header(BuildContext context, List<Item> items) {
    final total = items.fold<double>(0, (sum, item) => sum + (item.price ?? 0));
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.gutter,
        Spacing.s,
        Spacing.gutter,
        0,
      ),
      child: Column(
        children: [
          Text(formatTnd(total), style: AppText.headline(context)),
          const SizedBox(height: Spacing.m),
          _CategoryChart(items: items),
        ],
      ),
    );
  }

  /// Sticky filter pills: Category / Type / Color / Season outlined pills
  /// with chevrons, each opening a multi-select sheet; a Clear pill appears
  /// while filters are active; live result count caption underneath.
  Widget _filterBar(BuildContext context, int resultCount) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.gutter,
        Spacing.m,
        Spacing.gutter,
        Spacing.s,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              children: [
                FilterChipPill(
                  label: 'Category',
                  active: _categories.isNotEmpty,
                  trailingIcon: AppIcons.expandMore,
                  onTap: () => _pickMulti(
                    title: 'Category',
                    options: [
                      for (final category in Category.values)
                        _FilterOption(category.name, category.name),
                    ],
                    selected: _categories.map((cat) => cat.name).toSet(),
                    onApply: (values) => setState(() {
                      _categories
                        ..clear()
                        ..addAll(
                          values.map(
                            (v) =>
                                Category.values.firstWhere((x) => x.name == v),
                          ),
                        );
                    }),
                  ),
                ),
                const SizedBox(width: Spacing.s),
                FilterChipPill(
                  label: 'Type',
                  active: _types.isNotEmpty,
                  trailingIcon: AppIcons.expandMore,
                  onTap: () => _pickMulti(
                    title: 'Type',
                    options: _presentTypes(),
                    selected: _types,
                    onApply: (values) => setState(() {
                      _types
                        ..clear()
                        ..addAll(values);
                    }),
                  ),
                ),
                const SizedBox(width: Spacing.s),
                FilterChipPill(
                  label: 'Color',
                  active: _colors.isNotEmpty,
                  trailingIcon: AppIcons.expandMore,
                  onTap: () => _pickMulti(
                    title: 'Color',
                    options: _presentColors(),
                    selected: _colors,
                    onApply: (values) => setState(() {
                      _colors
                        ..clear()
                        ..addAll(values);
                    }),
                  ),
                ),
                const SizedBox(width: Spacing.s),
                FilterChipPill(
                  label: 'Season',
                  active: _seasons.isNotEmpty,
                  trailingIcon: AppIcons.expandMore,
                  onTap: () => _pickMulti(
                    title: 'Season',
                    options: [
                      _FilterOption('summer', Season.summer.name),
                      _FilterOption('winter', Season.winter.name),
                    ],
                    selected: _seasons.map((season) => season.name).toSet(),
                    onApply: (values) => setState(() {
                      _seasons
                        ..clear()
                        ..addAll(
                          values.map(
                            (v) => Season.values.firstWhere((x) => x.name == v),
                          ),
                        );
                    }),
                  ),
                ),
                if (_hasActiveFilters) ...[
                  const SizedBox(width: Spacing.s),
                  FilterChipPill(
                    label: 'Clear',
                    active: false,
                    onTap: _clearFilters,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$resultCount items',
            style: AppText.caption(context, color: c.inkSecondary),
          ),
        ],
      ),
    );
  }

  List<_FilterOption> _presentTypes() {
    final state = AppStateScope.of(context);
    final names = state.items
        .map((item) => item.subtype)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();
    return [for (final name in names) _FilterOption(name, name)];
  }

  /// Wardrobe colors actually in use, in curated-list order.
  List<_FilterOption> _presentColors() {
    final state = AppStateScope.of(context);
    final used = <String>{};
    for (final item in state.items) {
      if (item.colorPrimaryName != null) used.add(item.colorPrimaryName!);
      if (item.colorSecondaryName != null) used.add(item.colorSecondaryName!);
    }
    return [
      for (final named in kNamedColors)
        if (used.contains(named.name))
          _FilterOption(named.name, named.name, swatchHex: named.hex),
    ];
  }

  /// Generic multi-select sheet (design.md section 6.1): pill toggles plus
  /// an Apply black pill; empty selection means the filter is off. [onApply]
  /// receives the applied values and writes them into the owning filter set.
  Future<void> _pickMulti({
    required String title,
    required List<_FilterOption> options,
    required Set<String> selected,
    required void Function(Set<String> applied) onApply,
  }) async {
    if (options.isEmpty) return;
    final local = selected.toSet();
    final applied = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.gutter),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: AppText.title(sheetContext),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: const Icon(AppIcons.close, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.m),
                    Flexible(
                      child: Wrap(
                        spacing: Spacing.s,
                        runSpacing: Spacing.s,
                        children: [
                          for (final option in options)
                            FilterChipPill(
                              label: option.label,
                              active: local.contains(option.value),
                              swatchHex: option.swatchHex,
                              onTap: () => setSheetState(() {
                                if (local.contains(option.value)) {
                                  local.remove(option.value);
                                } else {
                                  local.add(option.value);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Spacing.m),
                    FilledButton(
                      onPressed: () =>
                          Navigator.of(sheetContext).pop(local.toSet()),
                      // Ink fill pairs with white content (design.md
                      // section 1).
                      child: Text(
                        'Apply',
                        style: AppText.button(
                          sheetContext,
                          color: AppColors.of(sheetContext).bg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (applied == null || !mounted) return;
    onApply(applied);
  }

  // ------------------------------------------------------------- grid glue

  Future<void> _showTileActions(Item item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(item.name, style: AppText.title(sheetContext)),
              const SizedBox(height: Spacing.m),
              OutlinedButton(
                onPressed: () => Navigator.of(sheetContext).pop('edit'),
                child: Text('Edit', style: AppText.button(sheetContext)),
              ),
              const SizedBox(height: Spacing.s),
              OutlinedButton(
                onPressed: () => Navigator.of(sheetContext).pop('delete'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.of(sheetContext).destructive,
                ),
                child: Text(
                  'Delete',
                  style: AppText.button(
                    sheetContext,
                    color: AppColors.of(sheetContext).destructive,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action == 'edit') {
      await Navigator.of(
        context,
      ).push(appRoute(DetailsFormScreen(existing: item)));
    } else if (action == 'delete') {
      // Destructive: confirm first, same sheet as the detail page
      // (userFlow.md flow 4, step 3).
      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        builder: (sheetContext) {
          final c = AppColors.of(sheetContext);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.gutter),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Remove ${item.name} from your closet?',
                    style: AppText.title(sheetContext),
                  ),
                  const SizedBox(height: Spacing.s),
                  Text(
                    "This can't be undone.",
                    style: AppText.caption(sheetContext),
                  ),
                  const SizedBox(height: Spacing.m),
                  OutlinedButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.destructive,
                      side: BorderSide(color: c.destructive),
                    ),
                    child: Text(
                      'Delete',
                      style: AppText.button(sheetContext, color: c.destructive),
                    ),
                  ),
                  const SizedBox(height: Spacing.s),
                  OutlinedButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: Text('Keep', style: AppText.button(sheetContext)),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (confirmed != true || !mounted) return;
      final state = AppStateScope.of(context);
      try {
        await state.deleteItem(item.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not delete the item: $e')),
          );
        }
      }
    }
  }
}

// ------------------------------------------------------------------ pieces

/// Pins the filter pill bar between the scrolling header and the grid
/// (design.md section 6.1: sticky filter pills; the grid scrolls beneath).
class _FilterHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;

  _FilterHeaderDelegate({required this.child});

  @override
  double get minExtent => 92;

  @override
  double get maxExtent => 92;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(color: AppColors.of(context).bg, child: child);
  }

  @override
  bool shouldRebuild(_FilterHeaderDelegate old) => old.child != child;
}

/// A filter-sheet option: display label, matched value, optional swatch.
class _FilterOption {
  final String label;
  final String value;
  final String? swatchHex;

  const _FilterOption(this.label, this.value, {this.swatchHex});
}

/// The "+ Add Piece" first tile (design.md section 6.1): ink plus and label
/// centered on a hairline-dashed square.
class _AddPieceTile extends StatelessWidget {
  final VoidCallback onTap;

  const _AddPieceTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(color: c.tileWhisper),
        child: CustomPaint(
          painter: _DashedPainter(color: c.hairline),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.add, size: 24, color: c.ink),
                const SizedBox(height: 4),
                Text('Add Piece', style: AppText.button(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedPainter extends CustomPainter {
  final Color color;

  _DashedPainter({required this.color});

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
  bool shouldRepaint(_DashedPainter old) => old.color != color;
}

/// The category bar chart (design.md section 6.1): one rounded block per
/// category with items, height proportional to count, colored per the
/// category tokens, value caption above, category label below.
class _CategoryChart extends StatelessWidget {
  final List<Item> items;

  const _CategoryChart({required this.items});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final byCategory = <Category, List<Item>>{};
    for (final item in items) {
      byCategory.putIfAbsent(item.category, () => []).add(item);
    }
    final entries = byCategory.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final maxCount = entries.first.value.length;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SizedBox(
              width: 72,
              child: Column(
                children: [
                  Text(
                    formatTndShort(entry.value),
                    style: AppText.caption(context),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 32 + (entry.value.length / maxCount) * 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.category(
                        entry.key,
                        Theme.brightnessOf(context),
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${entry.value.length}',
                      style: AppText.label(
                        context,
                        color: entry.key == Category.shoes ? c.ink : c.bg,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(entry.key.name, style: AppText.caption(context)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Formats a TND value with thin thousands grouping, e.g. "1 240 TND"
/// (design.md section 6.1 headline example).
String formatTnd(double value) {
  final whole = value.round().toString();
  final buffered = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    buffered.write(whole[i]);
    final remaining = whole.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) buffered.write(' ');
  }
  return '${buffered.toString()} TND';
}

/// Compact value caption for the chart blocks ("128 TND").
String formatTndShort(List<Item> items) {
  final sum = items.fold<double>(0, (total, item) => total + (item.price ?? 0));
  return '${sum.round()} TND';
}

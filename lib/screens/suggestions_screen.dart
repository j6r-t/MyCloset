import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../services/suggestion_engine.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/flat_lay_column.dart';
import '../widgets/shimmer.dart';

/// Screen 8 - Suggestions (tab root, design.md section 6.8): the top 3 as
/// vertical flat-lay columns (the shared renderer), each with its one-line
/// reason caption and one-tap save; the shuffle icon regenerates,
/// deprioritizing previously shown combos until the pool resets
/// (backend.md section 5.4; userFlow.md flow 6).
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({super.key});

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  List<PaletteGroup>? _palettes;

  /// Keys of combos already shown in this shuffle cycle; deprioritized
  /// until the pool is exhausted, then the cycle resets.
  final Set<String> _shown = {};

  List<Suggestion> _current = const [];

  bool _loading = true;
  bool _poolExhausted = false;

  @override
  void initState() {
    super.initState();
    // Defer the first generation: it reads the inherited AppState, which is
    // not allowed during initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _generate();
    });
  }

  Future<void> _generate() async {
    final state = AppStateScope.of(context);
    if (!mounted) return;
    if (!_loading) setState(() => _loading = true);

    // Palettes load once and are then cached for the session.
    _palettes ??= await loadPalettes();

    if (!mounted) return;
    final engine = SuggestionEngine(palettes: _palettes!);
    var results = engine.suggest(state.items, exclude: _shown, limit: 3);
    var exhausted = false;
    if (results.isEmpty && _shown.isNotEmpty) {
      // Pool exhausted: reset the cycle (userFlow.md flow 6, step 3).
      _shown.clear();
      exhausted = true;
      results = engine.suggest(state.items, limit: 3);
    }
    if (!mounted) return;
    setState(() {
      _current = results;
      for (final s in results) {
        _shown.add(s.key);
      }
      _poolExhausted = exhausted;
      _loading = false;
    });
  }

  Future<void> _saveAsOutfit(Suggestion suggestion) async {
    final state = AppStateScope.of(context);
    final name = _defaultName();
    try {
      await state.createOutfit(name, suggestion.slots);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved "$name" to outfits')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the outfit: $e')),
        );
      }
    }
  }

  String _defaultName() {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final now = DateTime.now();
    return 'Outfit · ${months[now.month - 1]} ${now.day}';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    final coreItems = state.items
        .where(
          (item) =>
              item.category == Category.dress ||
              item.category == Category.top ||
              item.category == Category.bottom ||
              item.category == Category.shoes,
        )
        .toList();

    Widget body;
    if (coreItems.length < 2) {
      body = EmptyState(
        statement: 'Not enough to combine yet.',
        sub: 'Add a few pieces - tops, bottoms, dresses, shoes.',
      );
    } else if (_loading) {
      body = ListView.builder(
        padding: const EdgeInsets.all(Spacing.gutter),
        itemCount: 3,
        itemBuilder: (_, _) => const Padding(
          padding: EdgeInsets.only(bottom: Spacing.m),
          child: _SuggestionSkeleton(),
        ),
      );
    } else if (_current.isEmpty) {
      body = const EmptyState(
        statement: 'Nothing pairs today.',
        sub: 'The season tags may be conflicting - try relaxing them.',
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          Spacing.gutter,
          Spacing.s,
          Spacing.gutter,
          148,
        ),
        itemCount: _current.length,
        itemBuilder: (context, index) {
          final suggestion = _current[index];
          return _SuggestionColumn(
            slots: suggestion.slots,
            reason: suggestion.breakdown.reason,
            poolExhausted: index == 0 && _poolExhausted,
            onSave: () => _saveAsOutfit(suggestion),
          );
        },
      );
    }

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tab-root title row with the shuffle action.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.gutter,
              Spacing.m,
              Spacing.gutter,
              0,
            ),
            child: Row(
              children: [
                Expanded(child: Text('Suggest', style: AppText.title(context))),
                IconButton(
                  icon: const Icon(AppIcons.shuffle, size: 22),
                  tooltip: 'Shuffle',
                  onPressed: coreItems.length < 2 ? null : _generate,
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// One suggestion: the vertical flat-lay column on the left (frameless,
/// non-overlapping), its reason caption and one-tap Save pill on the right.
class _SuggestionColumn extends StatelessWidget {
  final Map<OutfitSlot, Item> slots;
  final String reason;
  final bool poolExhausted;
  final VoidCallback onSave;

  const _SuggestionColumn({
    required this.slots,
    required this.reason,
    required this.poolExhausted,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.section),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 132,
            height: 300,
            child: FlatLayColumn(items: FlatLayColumn.ordered(slots)),
          ),
          const SizedBox(width: Spacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reason.isNotEmpty ? reason : 'A quiet combination',
                  style: AppText.fieldLabel(context, color: c.inkSecondary),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (poolExhausted) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Shuffled the whole wardrobe',
                    style: AppText.caption(context),
                  ),
                ],
                const SizedBox(height: Spacing.m),
                FilledButton(
                  onPressed: onSave,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.check, size: 18, color: c.bg),
                      const SizedBox(width: 8),
                      Text('Save', style: AppText.button(context, color: c.bg)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading skeleton: a column-shaped shimmer plus a caption block.
class _SuggestionSkeleton extends StatelessWidget {
  const _SuggestionSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        const SizedBox(
          width: 132,
          height: 300,
          child: ShimmerPlaceholder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        const SizedBox(width: Spacing.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 16,
                decoration: BoxDecoration(
                  color: c.tile,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(height: Spacing.m),
              FilledButton(
                onPressed: null,
                // Skeleton placeholder: always disabled, so the tile fill
                // pairs with ink-secondary (design.md section 1).
                child: Text(
                  'Save',
                  style: AppText.button(context, color: c.inkSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

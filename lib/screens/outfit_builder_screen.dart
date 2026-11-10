import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../services/suggestion_engine.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/cutout_image.dart';
import '../widgets/flat_lay_column.dart';

/// Screen 7 - Outfit builder (design.md section 6.7): a live vertical
/// flat-lay preview rendered exactly like a saved outfit's column, slot
/// chips beneath (Dress OR Top+Bottom, Shoes, Outerwear, Accessory - tap a
/// chip to pick a piece), the harmony readout as a caption word, and Save
/// as the black pill.
///
/// [seedItem] pre-seeds the builder - "Create fit" on an item detail page
/// opens the builder with that piece already in its slot.
class OutfitBuilderScreen extends StatefulWidget {
  /// Existing outfit to edit (null = build a new one).
  final int? existingOutfitId;
  final String? existingName;

  /// Item pre-seeded from the item detail's "Create fit" pill.
  final Item? seedItem;

  const OutfitBuilderScreen({
    super.key,
    this.existingOutfitId,
    this.existingName,
    this.seedItem,
  });

  @override
  State<OutfitBuilderScreen> createState() => _OutfitBuilderScreenState();
}

class _OutfitBuilderScreenState extends State<OutfitBuilderScreen> {
  final Map<OutfitSlot, Item> _slots = {};
  bool _initialized = false;
  bool _saving = false;

  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existingName ?? '');
    final seed = widget.seedItem;
    if (seed != null) {
      // The category names equal their slot names.
      final slot = OutfitSlot.values.firstWhere(
        (slot) => slot.name == seed.category.name,
      );
      _slots[slot] = seed;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ensureInitialized(AppState state) {
    if (_initialized) return;
    _initialized = true;
    if (widget.existingOutfitId != null) {
      final slots = state.slotsOf(widget.existingOutfitId!);
      for (final entry in slots.entries) {
        final item = state.itemById(entry.value);
        if (item != null) _slots[entry.key] = item;
      }
    }
  }

  /// Choosing a dress empties top and bottom (and vice versa) - the same
  /// invariant the database enforces on write (userFlow.md flow 5, step 4).
  void _setItem(OutfitSlot slot, Item item) {
    setState(() {
      if (slot == OutfitSlot.dress) {
        _slots.remove(OutfitSlot.top);
        _slots.remove(OutfitSlot.bottom);
      } else if (slot == OutfitSlot.top || slot == OutfitSlot.bottom) {
        _slots.remove(OutfitSlot.dress);
      }
      _slots[slot] = item;
    });
  }

  void _clearSlot(OutfitSlot slot) {
    setState(() => _slots.remove(slot));
  }

  bool get _torsoValid =>
      _slots.containsKey(OutfitSlot.dress) ||
      (_slots.containsKey(OutfitSlot.top) &&
          _slots.containsKey(OutfitSlot.bottom));

  bool get _canSave => _slots.isNotEmpty && _torsoValid;

  Future<void> _pickForSlot(OutfitSlot slot) async {
    final category = Category.values.firstWhere((cat) => cat.name == slot.name);
    final picked = await showModalBottomSheet<Item>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SlotItemPicker(category: category),
    );
    if (picked != null) _setItem(slot, picked);
  }

  Future<void> _save() async {
    if (!_canSave || _saving) return;
    setState(() => _saving = true);
    final state = AppStateScope.of(context);
    final name = _name.text.trim().isEmpty ? _defaultName() : _name.text.trim();

    try {
      if (widget.existingOutfitId != null) {
        await state.replaceOutfit(widget.existingOutfitId!, name, _slots);
      } else {
        await state.createOutfit(name, _slots);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the outfit: $e')),
        );
      }
    }
  }

  /// "Outfit · Nov 9" per userFlow.md flow 5, step 6.
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

  String _readoutWord(HarmonyBucket bucket) {
    switch (bucket) {
      case HarmonyBucket.harmonious:
        return 'Harmonious';
      case HarmonyBucket.mixed:
        return 'Mixed';
      case HarmonyBucket.clashing:
        return 'Clashing';
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    _ensureInitialized(state);
    final c = AppColors.of(context);
    final engine = const SuggestionEngine();

    final readout = _slots.length >= 2
        ? _readoutWord(engine.harmonyReadout(_slots))
        : null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(AppIcons.back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.existingOutfitId != null ? 'Edit outfit' : 'New outfit',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.gutter,
          Spacing.s,
          Spacing.gutter,
          Spacing.section * 2,
        ),
        children: [
          // Live vertical flat-lay preview - the same column renderer the
          // gallery uses (design.md section 6.7). Frameless, never
          // overlapping.
          SizedBox(
            height: 360,
            child: FlatLayColumn(
              items: FlatLayColumn.ordered(_slots),
              showMissing: _slots.isNotEmpty && !_torsoValid,
            ),
          ),
          const SizedBox(height: Spacing.s),

          // Harmony readout as one quiet caption word.
          Text(
            readout ?? 'Pick the pieces',
            textAlign: TextAlign.center,
            style: AppText.caption(context, color: c.inkSecondary),
          ),
          const SizedBox(height: Spacing.m),

          // Slot chips: tap to pick a piece, small close to clear.
          Wrap(
            spacing: Spacing.s,
            runSpacing: Spacing.s,
            children: [
              for (final slot in const [
                OutfitSlot.dress,
                OutfitSlot.top,
                OutfitSlot.bottom,
                OutfitSlot.shoes,
                OutfitSlot.outerwear,
                OutfitSlot.accessory,
              ])
                _SlotChip(
                  slot: slot,
                  item: _slots[slot],
                  onTap: () => _pickForSlot(slot),
                  onClear: () => _clearSlot(slot),
                ),
            ],
          ),
          const SizedBox(height: Spacing.m),

          if (!_torsoValid && _slots.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.m),
              child: Text(
                'A dress alone, or a top and a bottom together.',
                style: AppText.caption(context),
              ),
            ),
          TextField(
            controller: _name,
            style: AppText.value(context),
            decoration: InputDecoration(hintText: _defaultName()),
          ),
          const SizedBox(height: Spacing.m),
          FilledButton(
            onPressed: _canSave && !_saving ? _save : null,
            child: Text(
              widget.existingOutfitId != null ? 'Save changes' : 'Save outfit',
              // Ink fill pairs with white content (design.md section 1);
              // the disabled tile fill pairs with ink-secondary.
              style: AppText.button(
                context,
                color: _canSave && !_saving ? c.bg : c.inkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One slot chip (design.md section 6.7): outlined pill naming the slot,
/// showing the chosen piece's name once filled, with a small clear glyph.
class _SlotChip extends StatelessWidget {
  final OutfitSlot slot;
  final Item? item;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _SlotChip({
    required this.slot,
    required this.item,
    required this.onTap,
    required this.onClear,
  });

  String get _label {
    final base = switch (slot) {
      OutfitSlot.dress => 'Dress',
      OutfitSlot.top => 'Top',
      OutfitSlot.bottom => 'Bottom',
      OutfitSlot.shoes => 'Shoes',
      OutfitSlot.outerwear => 'Outerwear',
      OutfitSlot.accessory => 'Accessory',
    };
    final name = item?.name;
    if (name == null) return base;
    return name.length > 18
        ? '$base · ${name.substring(0, 18)}…'
        : '$base · $name';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final filled = item != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
        decoration: BoxDecoration(
          color: filled ? c.tile : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: c.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label,
              style: AppText.button(
                context,
              ).copyWith(fontSize: 13, color: filled ? c.ink : c.inkSecondary),
            ),
            if (filled) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: Icon(AppIcons.close, size: 16, color: c.inkSecondary),
              ),
            ] else
              Icon(AppIcons.add, size: 16, color: c.inkSecondary),
          ],
        ),
      ),
    );
  }
}

/// Modal picker for one slot: items of the slot's category with a small
/// search field (reuses flow 3's search semantics, per userFlow.md flow 5
/// step 3). Pieces render frameless, like the grid.
class _SlotItemPicker extends StatefulWidget {
  final Category category;

  const _SlotItemPicker({required this.category});

  @override
  State<_SlotItemPicker> createState() => _SlotItemPickerState();
}

class _SlotItemPickerState extends State<_SlotItemPicker> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final c = AppColors.of(context);
    final query = _search.text.trim().toLowerCase();
    final candidates = state.items
        .where((item) => item.category == widget.category)
        .where(
          (item) =>
              query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              (item.brand ?? '').toLowerCase().contains(query),
        )
        .toList();

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
                    'Choose ${widget.category.name}',
                    style: AppText.title(context),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(AppIcons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: Spacing.s),
            TextField(
              controller: _search,
              autofocus: false,
              onChanged: (_) => setState(() {}),
              style: AppText.value(context),
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(AppIcons.search, size: 20),
              ),
            ),
            const SizedBox(height: Spacing.m),
            Flexible(
              child: candidates.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: Spacing.section,
                      ),
                      child: Text(
                        'Nothing in this category yet.',
                        textAlign: TextAlign.center,
                        style: AppText.caption(context),
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: Spacing.gridGap,
                            mainAxisSpacing: Spacing.gridGap,
                            childAspectRatio: 0.75,
                          ),
                      itemCount: candidates.length,
                      itemBuilder: (context, index) {
                        final item = candidates[index];
                        return GestureDetector(
                          onTap: () => Navigator.of(context).pop(item),
                          child: Container(
                            color: c.tileWhisper,
                            padding: const EdgeInsets.all(8),
                            child: CutoutImage(
                              path: item.cutoutPath,
                              iconSize: 20,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

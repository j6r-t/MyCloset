import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../models/outfit.dart';
import '../services/suggestion_engine.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/cutout_image.dart';
import '../widgets/flat_lay_column.dart';
import 'details_form_screen.dart';
import 'item_detail_screen.dart';
import 'outfit_builder_screen.dart';
import 'outfits_gallery_screen.dart';

/// Outfit detail (reached from the outfits gallery, design.md section 6.6):
/// the full vertical flat-lay column, the name (tap to rename inline) with
/// its date caption, the harmony readout, then the outfit's components -
/// one hairline row per garment (thumbnail cutout, name, category, brand,
/// price in money-green, color swatch, size, layer type) with tap opening
/// the item detail and per-row edit/delete. Deleting a row empties that
/// slot (dashed placeholder per userFlow.md edge behaviors); deleting the
/// outfit confirms first, same as the gallery flow.
class OutfitDetailScreen extends StatefulWidget {
  final int outfitId;

  const OutfitDetailScreen({super.key, required this.outfitId});

  @override
  State<OutfitDetailScreen> createState() => _OutfitDetailScreenState();
}

class _OutfitDetailScreenState extends State<OutfitDetailScreen> {
  /// Inline rename state: null means the name renders as plain text.
  TextEditingController? _renameController;
  FocusNode? _renameFocus;

  @override
  void dispose() {
    _renameController?.dispose();
    _renameFocus?.dispose();
    super.dispose();
  }

  void _startRename(Outfit outfit) {
    setState(() {
      _renameController = TextEditingController(text: outfit.name);
      _renameFocus = FocusNode();
    });
    // Autofocus after the field enters the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renameFocus?.requestFocus();
    });
  }

  void _cancelRename() {
    setState(() {
      _renameController?.dispose();
      _renameController = null;
      _renameFocus?.dispose();
      _renameFocus = null;
    });
  }

  Future<void> _commitRename(String value) async {
    final controller = _renameController;
    if (controller == null) return;
    final name = value.trim();
    _cancelRename();
    if (name.isEmpty) return;
    try {
      await AppStateScope.of(context).renameOutfit(widget.outfitId, name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rename the outfit: $e')),
        );
      }
    }
  }

  // ---------------------------------------------------------------- actions

  Future<void> _confirmDeleteOutfit(Outfit outfit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${outfit.name}?'),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.of(dialogContext).destructive,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppStateScope.of(context).deleteOutfit(widget.outfitId);
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete the outfit: $e')),
        );
      }
    }
  }

  /// Per-row delete: empties that slot, keeping the outfit (userFlow.md
  /// edge behaviors: the emptied slot renders as a dashed placeholder).
  Future<void> _confirmRemoveSlot(Outfit outfit, OutfitSlot slot) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Remove this piece from ${outfit.name}?',
                style: AppText.title(sheetContext),
              ),
              const SizedBox(height: Spacing.s),
              Text(
                'The outfit keeps its other pieces.',
                style: AppText.caption(sheetContext),
              ),
              const SizedBox(height: Spacing.m),
              OutlinedButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.of(sheetContext).destructive,
                  side: BorderSide(
                    color: AppColors.of(sheetContext).destructive,
                  ),
                ),
                child: Text(
                  'Remove from outfit',
                  style: AppText.button(
                    sheetContext,
                    color: AppColors.of(sheetContext).destructive,
                  ),
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
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppStateScope.of(context).removeOutfitSlot(outfit.id, slot);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove the piece: $e')),
        );
      }
    }
  }

  // ------------------------------------------------------------ row widget

  /// Display order of the component rows: the same slot order the flat-lay
  /// column uses (dress, top, bottom, shoes, outerwear, accessory).
  static const List<OutfitSlot> _rowOrder = [
    OutfitSlot.dress,
    OutfitSlot.top,
    OutfitSlot.bottom,
    OutfitSlot.shoes,
    OutfitSlot.outerwear,
    OutfitSlot.accessory,
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final c = AppColors.of(context);

    // Read live: a rename, a slot removal, or an item edit round-trip all
    // reflect immediately; a deleted outfit pops back to the gallery.
    Outfit? found;
    for (final o in state.outfits) {
      if (o.id == widget.outfitId) found = o;
    }
    if (found == null) {
      return Scaffold(
        appBar: AppBar(leading: const SizedBox()),
        body: const SizedBox(),
      );
    }
    // Final local so Dart promotes through every closure below.
    final outfit = found;

    final slots = state.slotsOf(outfit.id);
    final slotItems = <OutfitSlot, Item>{};
    for (final entry in slots.entries) {
      final item = state.itemById(entry.value);
      if (item != null) slotItems[entry.key] = item;
    }
    final incomplete = OutfitsGalleryScreen.isIncomplete(slots);
    final engine = const SuggestionEngine();
    final harmony = slotItems.length >= 2
        ? switch (engine.harmonyReadout(slotItems)) {
            HarmonyBucket.harmonious => 'Harmonious',
            HarmonyBucket.mixed => 'Mixed',
            HarmonyBucket.clashing => 'Clashing',
          }
        : null;

    final renameController = _renameController;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(AppIcons.back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Outfit'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.gutter,
          Spacing.s,
          Spacing.gutter,
          Spacing.section * 2,
        ),
        children: [
          // Name (tap to rename inline) + date caption + harmony readout.
          if (renameController == null)
            GestureDetector(
              onTap: () => _startRename(outfit),
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      outfit.name,
                      style: AppText.title(context),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Icon(AppIcons.edit, size: 18, color: c.inkSecondary),
                ],
              ),
            )
          else
            TextField(
              controller: renameController,
              focusNode: _renameFocus,
              autofocus: true,
              style: AppText.title(context),
              textInputAction: TextInputAction.done,
              onSubmitted: _commitRename,
              decoration: InputDecoration(
                hintText: 'Outfit name',
                suffixIcon: IconButton(
                  icon: const Icon(AppIcons.check, size: 20),
                  onPressed: () =>
                      _commitRename(renameController.text),
                ),
              ),
            ),
          const SizedBox(height: 2),
          Text(
            harmony == null
                ? _formattedDate(outfit.createdAt)
                : '${_formattedDate(outfit.createdAt)}  ·  $harmony',
            style: AppText.caption(context),
          ),
          const SizedBox(height: Spacing.m),

          // The full flat-lay column - the same renderer as the gallery
          // (design.md section 6.6), dashed slot when the core is missing.
          SizedBox(
            height: 360,
            child: FlatLayColumn(
              items: FlatLayColumn.ordered(slotItems),
              showMissing: slotItems.isNotEmpty && incomplete,
            ),
          ),
          const SizedBox(height: Spacing.m),

          // Outfit-level actions: edit in builder (black) / delete (outlined).
          Row(
            children: [
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    appRoute(
                      OutfitBuilderScreen(
                        existingOutfitId: outfit.id,
                        existingName: outfit.name,
                      ),
                    ),
                  ),
                  child: Text(
                    'Edit in builder',
                    style: AppText.button(context, color: c.bg),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _confirmDeleteOutfit(outfit),
                  child: Text(
                    'Delete',
                    style: AppText.button(context, color: c.destructive),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.section),

          // Components: one hairline row per garment in the flat-lay order.
          Text('Pieces', style: AppText.label(context)),
          const SizedBox(height: Spacing.s),
          if (slotItems.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.section),
              child: Text(
                'No pieces left in this outfit.',
                textAlign: TextAlign.center,
                style: AppText.caption(context),
              ),
            )
          else
            for (final slot in _rowOrder)
              if (slotItems[slot] != null)
                _buildComponentRow(
                  context,
                  outfit,
                  slot,
                  slotItems[slot]!,
                ),
        ],
      ),
    );
  }

  String _formattedDate(DateTime date) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  /// Builds one component row for [slot] holding [item]: tap opens the
  /// item detail; edit opens the item's edit form; delete empties the slot
  /// (confirm sheet).
  Widget _buildComponentRow(
    BuildContext context,
    Outfit outfit,
    OutfitSlot slot,
    Item item,
  ) {
    return _ComponentRow(
      item: item,
      slotLabel: switch (slot) {
        OutfitSlot.dress => 'Dress',
        OutfitSlot.top => 'Top',
        OutfitSlot.bottom => 'Bottom',
        OutfitSlot.shoes => 'Shoes',
        OutfitSlot.outerwear => 'Outerwear',
        OutfitSlot.accessory => 'Accessory',
      },
      onTap: () => Navigator.of(context).push(appRoute(ItemDetailScreen(item: item))),
      onEdit: () => Navigator.of(context).push(
        appRoute(DetailsFormScreen(existing: item)),
      ),
      onDelete: () => _confirmRemoveSlot(outfit, slot),
    );
  }
}

/// One garment row in the components list: thumbnail cutout on a tile
/// square, name, category (and slot) with size, brand, price in
/// money-green, a color swatch dot, layer type when set, and per-row
/// edit/delete affordances.
class _ComponentRow extends StatelessWidget {
  final Item item;

  /// The outfit slot this piece occupies (may differ from the category for
  /// a top doubling as outerwear).
  final String slotLabel;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ComponentRow({
    required this.item,
    required this.slotLabel,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  String _formatPrice(double price) {
    final rounded = price.round();
    if ((price - rounded).abs() < 0.005) return rounded.toString();
    return price.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final detailLine = [
      slotLabel,
      if (item.size != null && item.size!.isNotEmpty) 'Size ${item.size}',
      if (item.layerType != null) 'Layer: ${item.layerType!.name}',
    ].join('  ·  ');

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: [
          // Thumbnail cutout on a tile square (the frameless rule's one
          // allowed container, design.md section 8).
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.tile,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(4),
              child: CutoutImage(path: item.cutoutPath, iconSize: 20),
            ),
          ),
          const SizedBox(width: Spacing.s),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.value(context),
                  ),
                  const SizedBox(height: 2),
                  Text(detailLine, style: AppText.caption(context)),
                  if (item.brand != null && item.brand!.isNotEmpty)
                    Text(item.brand!, style: AppText.caption(context)),
                ],
              ),
            ),
          ),
          const SizedBox(width: Spacing.s),
          // Color swatch dot.
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color(
                int.parse(item.colorPrimaryHex.substring(1), radix: 16),
              ),
              border: Border.all(color: c.hairline),
            ),
          ),
          const SizedBox(width: Spacing.s),
          if (item.price != null)
            Text(
              '${_formatPrice(item.price!)} USD/EUR',
              style: AppText.value(context, color: c.money),
            ),
          // Per-row edit / delete, 44px touch targets like the metadata
          // rows (accessibility floor).
          GestureDetector(
            onTap: onEdit,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Icon(AppIcons.edit, size: 20, color: c.inkSecondary),
              ),
            ),
          ),
          GestureDetector(
            onTap: onDelete,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Icon(AppIcons.delete, size: 20, color: c.inkSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

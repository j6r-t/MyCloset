import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/item.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/cutout_image.dart';
import '../widgets/metadata_row.dart';
import '../widgets/named_color_picker.dart';
import 'details_form_screen.dart';
import 'outfit_builder_screen.dart';

/// Screen 5 - Item detail (design.md section 6.5): hero cutout on a tile
/// card, action pills row - "Create fit" (black, pre-seeds the outfit
/// builder) / Edit / Delete (outlined) - then hairline metadata rows
/// including Size and Layer Type, each with a per-row pencil edit; delete
/// confirms via sheet.
class ItemDetailScreen extends StatefulWidget {
  final Item item;

  const ItemDetailScreen({super.key, required this.item});

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  bool _deleted = false;

  bool get _canLayer =>
      widget.item.category == Category.top ||
      widget.item.category == Category.outerwear;

  Future<void> _updateItem(Item updated) async {
    final state = AppStateScope.of(context);
    try {
      await state.updateItem(updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the change: $e')),
        );
      }
    }
  }

  // ------------------------------------------------------------ edit sheets

  /// Text-field edit sheet for one metadata row (per-row pencil edits).
  Future<void> _editText(
    BuildContext context,
    Item item, {
    required String title,
    String? initial,
    bool multiline = false,
    TextInputType? keyboardType,
    required Future<void> Function(String value) onSave,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.gutter),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(title, style: AppText.title(sheetContext)),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(AppIcons.close, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.s),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLines: multiline ? 3 : 1,
                    keyboardType: keyboardType,
                    style: AppText.value(sheetContext),
                  ),
                  const SizedBox(height: Spacing.m),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(sheetContext).pop(controller.text.trim()),
                    // Ink fill pairs with white content (design.md
                    // section 1).
                    child: Text(
                      'Save',
                      style: AppText.button(
                        sheetContext,
                        color: AppColors.of(sheetContext).bg,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    controller.dispose();
    if (value == null) return;
    await onSave(value);
  }

  /// Pill-selector edit sheet for fixed enums (category, season, layer).
  Future<void> _editEnum<T extends Enum>({
    required String title,
    required List<T> values,
    required T? selected,
    bool allowNone = false,
    required Future<void> Function(T? value) onSave,
  }) async {
    final picked = await showModalBottomSheet<T?>(
      context: context,
      builder: (sheetContext) {
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
                      child: Text(title, style: AppText.title(sheetContext)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(AppIcons.close, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.m),
                Wrap(
                  spacing: Spacing.s,
                  runSpacing: Spacing.s,
                  children: [
                    for (final value in values)
                      _SheetPill(
                        label: value.name,
                        active: value == selected,
                        onTap: () => Navigator.of(sheetContext).pop(value),
                      ),
                    if (allowNone)
                      _SheetPill(
                        label: 'none',
                        active: selected == null,
                        onTap: () => Navigator.of(sheetContext).pop(null),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == selected) return;
    await onSave(picked);
  }

  Future<void> _editPrimaryColor(Item item) async {
    final named = await showNamedColorPicker(context);
    if (named == null) return;
    await _updateItem(
      item.copyWith(colorPrimaryHex: named.hex, colorPrimaryName: named.name),
    );
  }

  // ---------------------------------------------------------------- actions

  Future<void> _confirmDelete(Item item) async {
    final c = AppColors.of(context);
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
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      await AppStateScope.of(context).deleteItem(widget.item.id);
      if (mounted) setState(() => _deleted = true);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete the item: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // Read fresh values from state so an edit round-trip shows live data.
    final state = AppStateScope.of(context);
    final item = state.itemById(widget.item.id) ?? widget.item;

    if (_deleted) return const SizedBox();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(AppIcons.back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.gutter,
          Spacing.s,
          Spacing.gutter,
          Spacing.section * 2,
        ),
        children: [
          // Hero cutout on its tile card (design.md section 6.5).
          AspectRatio(
            aspectRatio: 0.9,
            child: Container(
              decoration: BoxDecoration(
                color: c.tile,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(Spacing.m),
              child: CutoutImage(path: item.cutoutPath, iconSize: 36),
            ),
          ),
          const SizedBox(height: Spacing.m),

          // Action pills: Create fit (black) / Edit / Delete (outlined).
          Row(
            children: [
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(appRoute(OutfitBuilderScreen(seedItem: item))),
                  // Ink fill pairs with white content (design.md section 1).
                  child: Text(
                    'Create fit',
                    style: AppText.button(context, color: c.bg),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(appRoute(DetailsFormScreen(existing: item))),
                  child: Text('Edit', style: AppText.button(context)),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _confirmDelete(item),
                  child: Text(
                    'Delete',
                    style: AppText.button(context, color: c.destructive),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.m),

          // Hairline metadata rows, per-row pencil edits (design.md 6.5).
          MetadataRow(
            label: 'Value',
            editable: true,
            onEdit: () => _editText(
              context,
              item,
              title: 'Value (TND)',
              initial: item.price?.toString(),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onSave: (value) => _updateItem(
                item.copyWith(
                  price: double.tryParse(value.replaceAll(',', '.')),
                ),
              ),
            ),
            value: Text(
              item.price == null ? '—' : '${_formatPrice(item.price!)} TND',
              style: AppText.value(context, color: c.money),
            ),
          ),
          MetadataRow(
            label: 'Brand',
            editable: true,
            onEdit: () => _editText(
              context,
              item,
              title: 'Brand',
              initial: item.brand,
              onSave: (value) =>
                  _updateItem(item.copyWith(brand: _nullIfEmpty(value))),
            ),
            value: Text(item.brand ?? '—', style: AppText.value(context)),
          ),
          MetadataRow(
            label: 'Type',
            editable: true,
            onEdit: () => _editText(
              context,
              item,
              title: 'Type',
              initial: item.subtype,
              onSave: (value) =>
                  _updateItem(item.copyWith(subtype: _nullIfEmpty(value))),
            ),
            value: Text(item.subtype ?? '—', style: AppText.value(context)),
          ),
          MetadataRow(
            label: 'Garment Type',
            editable: true,
            onEdit: () => _editEnum(
              title: 'Garment type',
              values: Category.values,
              selected: item.category,
              onSave: (value) => _updateItem(
                item.copyWith(
                  category: value!,
                  // layer_type is null outside top/outerwear.
                  layerType:
                      value == Category.top || value == Category.outerwear
                      ? item.layerType
                      : null,
                ),
              ),
            ),
            value: Text(item.category.name, style: AppText.value(context)),
          ),
          MetadataRow(
            label: 'Size',
            editable: true,
            onEdit: () => _editText(
              context,
              item,
              title: 'Size',
              initial: item.size,
              onSave: (value) =>
                  _updateItem(item.copyWith(size: _nullIfEmpty(value))),
            ),
            value: Text(item.size ?? '—', style: AppText.value(context)),
          ),
          if (_canLayer)
            MetadataRow(
              label: 'Layer Type',
              editable: true,
              onEdit: () => _editEnum(
                title: 'Layer type',
                values: LayerType.values,
                selected: item.layerType,
                allowNone: true,
                onSave: (value) => _updateItem(item.copyWith(layerType: value)),
              ),
              value: Text(
                item.layerType?.name ?? '—',
                style: AppText.value(context),
              ),
            ),
          MetadataRow(
            label: 'Color',
            editable: true,
            onEdit: () => _editPrimaryColor(item),
            leading: _swatches(item, c),
            value: Text(_colorsLine(item), style: AppText.value(context)),
          ),
          // Condition only when graded (it stays optional in the form).
          if (item.condition != null)
            MetadataRow(
              key: const ValueKey('row-condition'),
              label: 'Condition',
              value: Text(
                conditionLabel(item.condition!),
                style: AppText.value(context),
              ),
            ),
          MetadataRow(
            label: 'Season',
            editable: true,
            onEdit: () => _editEnum(
              title: 'Season',
              values: Season.values,
              selected: item.season,
              onSave: (value) => _updateItem(item.copyWith(season: value!)),
            ),
            value: Text(item.season.name, style: AppText.value(context)),
          ),
          if (item.fabric != null)
            MetadataRow(
              label: 'Fabric',
              editable: true,
              onEdit: () => _editText(
                context,
                item,
                title: 'Fabric',
                initial: item.fabric,
                onSave: (value) =>
                    _updateItem(item.copyWith(fabric: _nullIfEmpty(value))),
              ),
              value: Text(item.fabric!, style: AppText.value(context)),
            ),
          if (item.notes != null && item.notes!.isNotEmpty)
            MetadataRow(
              label: 'Notes',
              editable: true,
              onEdit: () => _editText(
                context,
                item,
                title: 'Notes',
                initial: item.notes,
                multiline: true,
                onSave: (value) =>
                    _updateItem(item.copyWith(notes: _nullIfEmpty(value))),
              ),
              value: Text(item.notes!, style: AppText.value(context)),
            ),
        ],
      ),
    );
  }

  String? _nullIfEmpty(String value) => value.isEmpty ? null : value;

  String _formatPrice(double price) {
    final rounded = price.round();
    if ((price - rounded).abs() < 0.005) return rounded.toString();
    return price.toStringAsFixed(2);
  }

  String _colorsLine(Item item) {
    final parts = <String>[];
    if (item.colorPrimaryName != null) parts.add(item.colorPrimaryName!);
    if (item.colorSecondaryName != null) parts.add(item.colorSecondaryName!);
    if (parts.isEmpty) parts.add(item.colorPrimaryHex);
    return parts.join('  ·  ');
  }

  Widget _swatches(Item item, AppColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final hex in [
          item.colorPrimaryHex,
          if (item.colorSecondaryHex != null) item.colorSecondaryHex!,
        ])
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(int.parse(hex.substring(1), radix: 16)),
                border: Border.all(color: c.hairline),
              ),
            ),
          ),
      ],
    );
  }
}

/// Single-select pill inside the edit sheets.
class _SheetPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SheetPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
        decoration: BoxDecoration(
          color: active ? c.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: active ? c.ink : c.hairline),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppText.button(context, color: active ? c.bg : c.ink),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../data/named_colors.dart';
import '../models/enums.dart';
import '../models/item.dart';
import '../services/color_extraction_service.dart';
import '../services/identification_pipeline.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/cutout_image.dart';
import '../widgets/named_color_picker.dart';

/// Screen 4 - Add item, details; also the edit form (userFlow.md flow 4,
/// step 2, pre-filled). Fields in Fitted's order (design.md section 6.4):
/// Value, Brand, Type, Garment Type, Size, Layer Type (top/outerwear only),
/// Color, Condition, Season, Fabric, Notes. Name is optional and defaults to
/// "Piece #id" on save.
class DetailsFormScreen extends StatefulWidget {
  /// Draft original path when creating from the capture flow.
  final String? draftOriginalPath;

  /// Draft cutout path (may equal the original after segmentation fallback).
  final String? draftCutoutPath;

  /// Existing item when editing.
  final Item? existing;

  /// Result of the identification screen's successful lookup. Add mode
  /// only: its suggestions prefill the EMPTY brand/type/price fields with
  /// a brief "auto" chip each. Ignored in edit mode.
  final IdentificationResult? prefill;

  const DetailsFormScreen({
    super.key,
    this.draftOriginalPath,
    this.draftCutoutPath,
    this.existing,
    this.prefill,
  }) : assert(
         (draftOriginalPath != null) != (existing != null),
         'Either draft paths (new item) or an existing item are required',
       );

  @override
  State<DetailsFormScreen> createState() => _DetailsFormScreenState();
}

/// The rows the identification run can touch.
enum _AutoField { name, brand, price, subtype, size, layerType, category }

/// Display label for a [Condition] (Fitted's wording); the enum's camelCase
/// names are identifiers, not UI copy, and the database stores the
/// snake_case dbValue - so the wording lives here, next to the only rows
/// that render it. Shared with the item detail screen.
String conditionLabel(Condition condition) => switch (condition) {
      Condition.newWithTags => 'New with tags',
      Condition.newWithoutTags => 'New without tags',
      Condition.likeNew => 'Like new',
      Condition.good => 'Good',
      Condition.worn => 'Worn',
    };

class _DetailsFormScreenState extends State<DetailsFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _subtype;
  late final TextEditingController _brand;
  late final TextEditingController _price;
  late final TextEditingController _size;
  late final TextEditingController _fabric;
  late final TextEditingController _notes;

  late Category _category;
  late Season _season;
  LayerType? _layerType;
  Condition? _condition;
  late String _primaryHex;
  String? _primaryName;
  late String? _secondaryHex;
  String? _secondaryName;

  bool _saving = false;

  // ------------------------------------------------- online auto-fill (add)

  /// True when the form was opened for a new item with neither
  /// identification API key set: the setup caption explains why nothing was
  /// auto-filled (the identification screen skips itself in that case).
  bool _noKeys = false;

  /// Rows the identification screen's result filled; each carries a brief
  /// "auto" chip that clears after two seconds so the user sees what the
  /// search contributed.
  final Set<_AutoField> _autoFilled = {};
  Timer? _autoFillChipTimer;

  /// New-item drafts only: blocks pops (system back included) until the
  /// draft images are cleaned up; flipped before the programmatic pop so
  /// the PopScope handler lets it through. Editing an existing item has no
  /// drafts and pops normally.
  bool get _guardsDrafts => widget.existing == null;
  bool _canPop = false;

  /// Re-entry guard for the PopScope handler.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _subtype = TextEditingController(text: existing?.subtype ?? '');
    _brand = TextEditingController(text: existing?.brand ?? '');
    _price = TextEditingController(
      text: existing?.price == null ? '' : existing!.price!.toString(),
    );
    _size = TextEditingController(text: existing?.size ?? '');
    _fabric = TextEditingController(text: existing?.fabric ?? '');
    _notes = TextEditingController(text: existing?.notes ?? '');
    _category = existing?.category ?? Category.top;
    _season = existing?.season ?? Season.all;
    _layerType = existing?.layerType;
    _condition = existing?.condition;

    // Fallback colors before (possible) extraction returns.
    const fallback = NamedColor('grey', '#8A8A8A');
    _primaryHex = existing?.colorPrimaryHex ?? fallback.hex;
    _primaryName = existing?.colorPrimaryName ?? fallback.name;
    _secondaryHex = existing?.colorSecondaryHex;
    _secondaryName = existing?.colorSecondaryName;

    if (existing == null) {
      _extractColors();
      // The identification screen owns running the lookup now; this form
      // only receives its result (or explains a keyless skip).
      final prefill = widget.prefill;
      if (prefill != null) {
        _applyPrefill(prefill);
      } else {
        final state = _stateMaybe;
        _noKeys =
            state == null ||
            !(state.serpApiKeySet || state.visionApiKeySet);
      }
    }
  }

  @override
  void dispose() {
    _autoFillChipTimer?.cancel();
    _name.dispose();
    _subtype.dispose();
    _brand.dispose();
    _price.dispose();
    _size.dispose();
    _fabric.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _canLayer =>
      _category == Category.top || _category == Category.outerwear;

  /// Auto-detected colors from the draft image (backend.md section 4).
  /// Extraction never blocks saving: on failure the neutral fallback above
  /// stays and the user can correct via the named-color picker.
  Future<void> _extractColors() async {
    final path = widget.draftCutoutPath ?? widget.draftOriginalPath;
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null || !mounted) return;
      // Downscale before extraction: when segmentation fell back to the
      // original photo the image is up to 1600px. 320px is plenty for
      // k-means and keeps this off the UI thread's memory budget.
      final small = img.copyResize(decoded, width: 320);
      final extracted = const ColorExtractionService().extract(small);
      if (!mounted) return;
      setState(() {
        _primaryHex = extracted.primaryHex ?? _primaryHex;
        _primaryName = extracted.primaryName ?? _primaryName;
        _secondaryHex = extracted.secondaryHex;
        _secondaryName = extracted.secondaryName;
      });
    } catch (e) {
      debugPrint('Color extraction failed, keeping fallback: $e');
    }
  }

  /// The stored color as a curated [NamedColor] so the wheel pre-marks it;
  /// identity comes from the closed vocabulary, so match by name.
  NamedColor? _currentNamed(bool primary) {
    final name = primary ? _primaryName : _secondaryName;
    if (name == null) return null;
    for (final n in kNamedColors) {
      if (n.name == name) return n;
    }
    return null;
  }

  Future<void> _pickColor({required bool primary}) async {
    final named = await showNamedColorPicker(
      context,
      current: _currentNamed(primary),
    );
    if (named == null || !mounted) return;
    setState(() {
      if (primary) {
        _primaryHex = named.hex;
        _primaryName = named.name;
      } else {
        _secondaryHex = named.hex;
        _secondaryName = named.name;
      }
    });
  }

  /// Single-select pill sheet for a fixed enum (category / season); tapping
  /// a pill applies it and closes.
  Future<T?> _pickEnum<T extends Enum>({
    required String title,
    required List<T> values,
    required T selected,
  }) {
    return showModalBottomSheet<T>(
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
                      FilterPill(
                        label: value.name,
                        active: value == selected,
                        onTap: () => Navigator.of(sheetContext).pop(value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    final price = double.tryParse(_price.text.trim().replaceAll(',', '.'));
    final state = AppStateScope.of(context);
    final name = _name.text.trim();

    try {
      if (widget.existing != null) {
        final existing = widget.existing!;
        // Built explicitly instead of via copyWith: an optional field the
        // user cleared (layer type pill toggled off, condition deselected)
        // must write null, which copyWith's null-preserving defaults cannot
        // express.
        await state.updateItem(
          Item(
            id: existing.id,
            // Name optional: falls back to the Piece #<id> default.
            name: name.isEmpty ? 'Piece #${existing.id}' : name,
            category: _category,
            subtype: _blankToNull(_subtype.text),
            brand: _blankToNull(_brand.text),
            price: price,
            size: _blankToNull(_size.text),
            layerType: _canLayer ? _layerType : null,
            condition: _condition,
            season: _season,
            fabric: _blankToNull(_fabric.text),
            notes: _blankToNull(_notes.text),
            colorPrimaryHex: _primaryHex,
            colorPrimaryName: _primaryName,
            colorSecondaryHex: _secondaryHex,
            colorSecondaryName: _secondaryName,
            imagePath: existing.imagePath,
            cutoutPath: existing.cutoutPath,
            createdAt: existing.createdAt,
          ),
        );
        if (mounted) Navigator.of(context).pop();
      } else {
        final id = await state.saveDraftItem(
          // Empty name is defaulted to "Piece #<id>" after the row insert
          // (design.md section 6.4).
          name: name,
          category: _category,
          subtype: _blankToNull(_subtype.text),
          brand: _blankToNull(_brand.text),
          price: price,
          size: _blankToNull(_size.text),
          layerType: _layerType,
          condition: _condition,
          season: _season,
          fabric: _blankToNull(_fabric.text),
          notes: _blankToNull(_notes.text),
          colorPrimaryHex: _primaryHex,
          colorPrimaryName: _primaryName,
          colorSecondaryHex: _secondaryHex,
          colorSecondaryName: _secondaryName,
          draftOriginalPath: widget.draftOriginalPath!,
          draftCutoutPath: widget.draftCutoutPath,
        );
        if (mounted) {
          // Let the saved state through the draft-guarding PopScope.
          setState(() => _canPop = true);
          Navigator.of(context).pop(id);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save the item: $e')));
      }
    }
  }

  String? _blankToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  // --------------------------------------------------- online identification

  /// One-shot AppState read without registering a dependency (safe from
  /// initState).
  AppState? get _stateMaybe =>
      context.getInheritedWidgetOfExactType<AppStateScope>()?.notifier;

  /// Applies the identification screen's successful result: a suggestion
  /// only ever lands in an EMPTY field - the user's text always wins. Each
  /// filled row shows a brief "auto" chip (2s) so the user sees what the
  /// search contributed.
  void _applyPrefill(IdentificationResult result) {
    final applied = <_AutoField>{};
    // Garment Type FIRST: the layer-type step below reads _canLayer, which
    // depends on _category. There is no "empty" state to check - in add
    // mode the category is still the untouched `top` default at this point
    // (prefill runs in initState, before any user input), so the
    // identification is authoritative for it here.
    final category = result.suggestedCategory;
    if (category != null) {
      _category = category;
      applied.add(_AutoField.category);
      // layer_type is null outside top/outerwear (backend.md section 2.1);
      // a category that cannot layer also drops a carried-over layerType.
      if (!_canLayer) _layerType = null;
    }
    final name = result.suggestedName;
    if (name != null && _name.text.trim().isEmpty) {
      _name.text = name;
      applied.add(_AutoField.name);
    }
    final brand = result.suggestedBrand;
    if (brand != null && _brand.text.trim().isEmpty) {
      _brand.text = brand;
      applied.add(_AutoField.brand);
    }
    final subtype = result.suggestedSubtype;
    if (subtype != null && _subtype.text.trim().isEmpty) {
      _subtype.text = subtype;
      applied.add(_AutoField.subtype);
    }
    final size = result.suggestedSize;
    if (size != null && _size.text.trim().isEmpty) {
      _size.text = size;
      applied.add(_AutoField.size);
    }
    final layerType = result.suggestedLayerType;
    // Only top/outerwear carry a layering role; other categories keep their
    // null default (backend.md section 2.1).
    if (layerType != null && _canLayer && _layerType == null) {
      _layerType = layerType;
      applied.add(_AutoField.layerType);
    }
    final price = result.suggestedPriceValue?.toString() ??
        _parseablePrice(result.suggestedPriceText);
    if (price != null && _price.text.trim().isEmpty) {
      _price.text = price;
      applied.add(_AutoField.price);
    }
    if (applied.isEmpty) return;
    setState(() => _autoFilled.addAll(applied));
    _autoFillChipTimer?.cancel();
    _autoFillChipTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(_autoFilled.clear);
    });
  }

  /// Price string as the pipeline's raw source text, normalized to a
  /// parseable number; null when nothing usable.
  String? _parseablePrice(String? text) {
    if (text == null) return null;
    final value = double.tryParse(text.replaceAll(',', '.'));
    return value?.toString();
  }

  /// Quiet caption line under the header, only for the keyless add case;
  /// the successful-prefill and manual-fill forms stay silent here.
  Widget? _identificationBanner() {
    if (!_noKeys) return null;
    return Center(
      child: Text(
        'Add your SerpAPI key in Settings to auto-fill details',
        style: AppText.caption(context),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// Trailing inline signal for an auto-fillable row: an "auto" chip on
  /// rows the identification result filled.
  Widget? _rowSuffix(_AutoField field) {
    if (_autoFilled.contains(field)) {
      final c = AppColors.of(context);
      return Container(
        key: ValueKey('auto-$field'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: c.hairline),
        ),
        child: Text('auto', style: AppText.caption(context)),
      );
    }
    return null;
  }

  /// Cancel while creating: discard the draft images (userFlow.md flow 2,
  /// step 5 - no orphans on disk). Runs for both the back button and the
  /// system back gesture via PopScope.
  Future<void> _cancel() async {
    if (!_guardsDrafts) {
      Navigator.of(context).pop();
      return;
    }
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    try {
      await AppStateScope.of(context).storage.clearTmp();
    } catch (_) {
      // Never block the pop on a cleanup failure.
    }
    if (!mounted) return;
    setState(() => _canPop = true);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isNew = widget.existing == null;
    final banner = isNew ? _identificationBanner() : null;
    final thumbPath =
        widget.draftCutoutPath ??
        widget.draftOriginalPath ??
        widget.existing?.cutoutPath;

    return PopScope(
      canPop: !_guardsDrafts || _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_leaving) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(AppIcons.back),
            onPressed: _cancel,
          ),
          title: Text(isNew ? 'Details' : 'Edit details'),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              Spacing.gutter,
              Spacing.m,
              Spacing.gutter,
              Spacing.section * 2,
            ),
            children: [
              // Cutout floating on its tile (design.md section 6.4).
              Center(
                child: Container(
                  width: 140,
                  height: 140,
                  padding: const EdgeInsets.all(Spacing.s),
                  decoration: BoxDecoration(
                    color: c.tile,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: thumbPath == null
                      ? Icon(AppIcons.hanger, size: 28, color: c.hairline)
                      : CutoutImage(path: thumbPath, iconSize: 28),
                ),
              ),
              const SizedBox(height: Spacing.section),

              // Quiet auto-fill setup caption (add mode, keys absent only):
              // explains why nothing was looked up. Success shows the "auto"
              // chips inline on the filled rows instead.
              if (banner != null) ...[
                banner,
                const SizedBox(height: Spacing.m),
              ],

              // Fitted's field order (design.md section 6.4). Name first,
              // optional. The auto-fillable rows carry the post-fill "auto"
              // chips.
              _Row(
                key: const ValueKey('row-name'),
                label: 'Name',
                suffix: _rowSuffix(_AutoField.name),
                child: _textField(_name, hint: 'Optional'),
              ),
              _Row(
                key: const ValueKey('row-price'),
                label: 'Value (USD/EUR)',
                suffix: _rowSuffix(_AutoField.price),
                child: _textField(
                  _price,
                  hint: '0',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              _Row(
                key: const ValueKey('row-brand'),
                label: 'Brand',
                suffix: _rowSuffix(_AutoField.brand),
                child: _textField(_brand),
              ),
              _Row(
                key: const ValueKey('row-subtype'),
                label: 'Type',
                suffix: _rowSuffix(_AutoField.subtype),
                child: _textField(_subtype, hint: 't-shirt, blazer…'),
              ),
              _Row(
                label: 'Garment Type',
                suffix: _rowSuffix(_AutoField.category),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _category.name,
                        style: AppText.value(context),
                      ),
                    ),
                    Icon(AppIcons.expandMore, size: 18, color: c.inkSecondary),
                  ],
                ),
                onTap: () async {
                  final picked = await _pickEnum(
                    title: 'Garment type',
                    values: Category.values,
                    selected: _category,
                  );
                  if (picked == null || !mounted) return;
                  setState(() {
                    _category = picked;
                    // layer_type is null outside top/outerwear (backend.md
                    // section 2.1).
                    if (!_canLayer) _layerType = null;
                  });
                },
              ),
              _Row(
                key: const ValueKey('row-size'),
                label: 'Size',
                suffix: _rowSuffix(_AutoField.size),
                child: _textField(_size, hint: 'M, 40…'),
              ),
              if (_canLayer)
                _Row(
                  key: const ValueKey('row-layer-type'),
                  label: 'Layer Type',
                  suffix: _rowSuffix(_AutoField.layerType),
                  child: Wrap(
                    spacing: Spacing.s,
                    children: [
                      for (final layer in LayerType.values)
                        FilterPill(
                          label: layer.name,
                          active: _layerType == layer,
                          compact: true,
                          onTap: () => setState(() {
                            _layerType = _layerType == layer ? null : layer;
                          }),
                        ),
                    ],
                  ),
                ),
              _Row(
                label: 'Color',
                child: GestureDetector(
                  onTap: () => _pickColor(primary: true),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      _swatchDot(_primaryHex, c),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _primaryName ?? _primaryHex,
                          style: AppText.value(context),
                        ),
                      ),
                      Icon(AppIcons.edit, size: 20, color: c.inkSecondary),
                    ],
                  ),
                ),
              ),
              if (_secondaryHex != null)
                _Row(
                  label: 'Accent color',
                  child: GestureDetector(
                    onTap: () => _pickColor(primary: false),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        _swatchDot(_secondaryHex!, c),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _secondaryName ?? _secondaryHex!,
                            style: AppText.value(context),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(() {
                            _secondaryHex = null;
                            _secondaryName = null;
                          }),
                          child: Icon(
                            AppIcons.close,
                            size: 20,
                            color: c.inkSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Condition (schema v4, Fitted-inspired): optional pill
              // selector like Layer Type, any category; tapping the active
              // pill deselects it.
              _Row(
                key: const ValueKey('row-condition'),
                label: 'Condition',
                child: Wrap(
                  spacing: Spacing.s,
                  runSpacing: Spacing.s,
                  children: [
                    for (final condition in Condition.values)
                      FilterPill(
                        key: ValueKey('condition-${condition.dbValue}'),
                        label: conditionLabel(condition),
                        active: _condition == condition,
                        compact: true,
                        onTap: () => setState(() {
                          _condition = _condition == condition ? null : condition;
                        }),
                      ),
                  ],
                ),
              ),
              _Row(
                label: 'Season',
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_season.name, style: AppText.value(context)),
                    ),
                    Icon(AppIcons.expandMore, size: 18, color: c.inkSecondary),
                  ],
                ),
                onTap: () async {
                  final picked = await _pickEnum(
                    title: 'Season',
                    values: Season.values,
                    selected: _season,
                  );
                  if (picked == null || !mounted) return;
                  setState(() => _season = picked);
                },
              ),
              _Row(label: 'Fabric', child: _textField(_fabric)),
              _Row(
                label: 'Notes',
                child: _textField(_notes, hint: 'Optional', maxLines: 3),
              ),
              const SizedBox(height: Spacing.section),
              FilledButton(
                onPressed: _saving ? null : _save,
                // Ink fill pairs with white content (design.md section 1);
                // the disabled tile fill pairs with ink-secondary.
                child: Text(
                  'Save item',
                  style: AppText.button(
                    context,
                    color: _saving ? c.inkSecondary : c.bg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: AppText.value(context),
      decoration: InputDecoration(hintText: hint),
    );
  }

  /// The current color at a glance. Outlined in ink-secondary, not the
  /// hairline token - light colors vanish against the white page otherwise
  /// (same fix as the item detail screen's bubbles).
  Widget _swatchDot(String hex, AppColors c) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // 0xFF prefix: '#RRGGBB' parsed bare yields 0x00RRGGBB - alpha 0,
        // a fully transparent dot (the "empty bubbles" bug).
        color: Color(0xFF000000 | int.parse(hex.substring(1), radix: 16)),
        border: Border.all(color: c.inkSecondary, width: 1),
      ),
    );
  }
}

/// One hairline form row (design.md section 6.4): label left, field right,
/// optional trailing signal (running caption / "auto" chip).
class _Row extends StatelessWidget {
  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? suffix;

  const _Row({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: GestureDetector(
        onTap: onTap,
        behavior: onTap == null
            ? HitTestBehavior.deferToChild
            : HitTestBehavior.opaque,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 116,
              child: Text(label, style: AppText.fieldLabel(context)),
            ),
            Expanded(child: child),
            if (suffix != null) ...[
              const SizedBox(width: Spacing.s),
              suffix!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Single-select pill used inside forms and sheets: hairline border with ink
/// text; active state is the black fill with white text. 15/medium labels.
class FilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Slightly smaller paddings for inline selectors like Layer Type.
  final bool compact;

  const FilterPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        height: compact ? 32 : 36,
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : Spacing.m),
        decoration: BoxDecoration(
          color: active ? c.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: active ? c.ink : c.hairline),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppText.button(
            context,
            color: active ? c.bg : c.ink,
          ).copyWith(fontSize: compact ? 13 : 15),
        ),
      ),
    );
  }
}


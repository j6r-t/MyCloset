import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:material_symbols_icons/symbols.dart';

import '../data/named_colors.dart';
import '../models/enums.dart';
import '../models/item.dart';
import '../services/color_extraction_service.dart';
import '../services/identification_pipeline.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import 'settings_screen.dart';
import '../widgets/cutout_image.dart';
import '../widgets/named_color_picker.dart';
import '../widgets/shimmer.dart';

/// Screen 4 - Add item, details; also the edit form (userFlow.md flow 4,
/// step 2, pre-filled). Fields in Fitted's order (design.md section 6.4):
/// Value, Brand, Type, Garment Type, Size, Layer Type (top/outerwear only),
/// Color, Season, Fabric, Notes. Name is optional and defaults to
/// "Piece #id" on save.
class DetailsFormScreen extends StatefulWidget {
  /// Draft original path when creating from the capture flow.
  final String? draftOriginalPath;

  /// Draft cutout path (may equal the original after segmentation fallback).
  final String? draftCutoutPath;

  /// Existing item when editing.
  final Item? existing;

  const DetailsFormScreen({
    super.key,
    this.draftOriginalPath,
    this.draftCutoutPath,
    this.existing,
  }) : assert(
         (draftOriginalPath != null) != (existing != null),
         'Either draft paths (new item) or an existing item are required',
       );

  @override
  State<DetailsFormScreen> createState() => _DetailsFormScreenState();
}

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
  late String _primaryHex;
  String? _primaryName;
  late String? _secondaryHex;
  String? _secondaryName;

  bool _saving = false;

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

    // Fallback colors before (possible) extraction returns.
    const fallback = NamedColor('grey', '#8A8A8A');
    _primaryHex = existing?.colorPrimaryHex ?? fallback.hex;
    _primaryName = existing?.colorPrimaryName ?? fallback.name;
    _secondaryHex = existing?.colorSecondaryHex;
    _secondaryName = existing?.colorSecondaryName;

    if (existing == null) {
      _extractColors();
    }
  }

  @override
  void dispose() {
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
        await state.updateItem(
          widget.existing!.copyWith(
            // Name optional: falls back to the Piece #<id> default.
            name: name.isEmpty ? 'Piece #${widget.existing!.id}' : name,
            category: _category,
            subtype: _blankToNull(_subtype.text),
            brand: _blankToNull(_brand.text),
            price: price,
            size: _blankToNull(_size.text),
            layerType: _layerType,
            season: _season,
            fabric: _blankToNull(_fabric.text),
            notes: _blankToNull(_notes.text),
            colorPrimaryHex: _primaryHex,
            colorPrimaryName: _primaryName,
            colorSecondaryHex: _secondaryHex,
            colorSecondaryName: _secondaryName,
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

  /// True when the "Identify online" pill shows (task spec): always in edit
  /// mode; in add mode only while both name and brand are still empty.
  bool get _showIdentifyPill {
    if (widget.existing != null) return true;
    return _name.text.trim().isEmpty && _brand.text.trim().isEmpty;
  }

  /// Runs the opt-in online lookup on the cutout (or the original when
  /// segmentation fell back) and shows the results sheet.
  Future<void> _identifyOnline() async {
    final imagePath = widget.existing?.cutoutPath ??
        widget.draftCutoutPath ??
        widget.draftOriginalPath;
    if (imagePath == null) return;
    await showIdentificationSheet(
      context,
      imagePath: imagePath,
      brand: _brand.text.trim(),
      subtype: _subtype.text.trim(),
      categoryLabel: _category.name,
      currentValues: {
        IdentificationTarget.brand: _brand.text.trim(),
        IdentificationTarget.subtype: _subtype.text.trim(),
        IdentificationTarget.price: _price.text.trim(),
      },
      onApply: _applySuggestion,
    );
  }

  /// Fills ONLY the empty field a suggestion targets. The sheet already
  /// confirms with the user before touching a non-empty field; this is the
  /// second guard so a user-entered value can never be overwritten.
  void _applySuggestion(IdentificationTarget target, String value) {
    if (!mounted) return;
    bool applied = false;
    setState(() {
      switch (target) {
        case IdentificationTarget.brand:
          if (_brand.text.trim().isEmpty) {
            _brand.text = value;
            applied = true;
          }
          break;
        case IdentificationTarget.subtype:
          if (_subtype.text.trim().isEmpty) {
            _subtype.text = value;
            applied = true;
          }
          break;
        case IdentificationTarget.price:
          if (_price.text.trim().isEmpty &&
              double.tryParse(value) != null) {
            _price.text = value;
            applied = true;
          }
          break;
      }
    });
    if (!applied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Field already filled - kept your value')),
      );
    }
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

              // Online identification (opt-in, the app's only networked
              // feature): edit mode always; add mode only while name and
              // brand are both still empty (task spec). Controllers drive
              // the visibility, so typing fills it in without a save.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _name,
                builder: (context, name, _) =>
                    ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _brand,
                  builder: (context, brand, _) {
                    if (!_showIdentifyPill) return const SizedBox.shrink();
                    return Center(
                      child: OutlinedButton.icon(
                        onPressed: _identifyOnline,
                        icon: const Icon(Symbols.travel_explore, size: 20),
                        label: const Text('Identify online'),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: Spacing.section),

              // Fitted's field order (design.md section 6.4). Name first,
              // optional.
              _Row(
                label: 'Name',
                child: _textField(_name, hint: 'Optional'),
              ),
              _Row(
                label: 'Value (TND)',
                child: _textField(
                  _price,
                  hint: '0',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              _Row(label: 'Brand', child: _textField(_brand)),
              _Row(
                label: 'Type',
                child: _textField(_subtype, hint: 't-shirt, blazer…'),
              ),
              _Row(
                label: 'Garment Type',
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
                label: 'Size',
                child: _textField(_size, hint: 'M, 40…'),
              ),
              if (_canLayer)
                _Row(
                  label: 'Layer Type',
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

  Widget _swatchDot(String hex, AppColors c) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color(int.parse(hex.substring(1), radix: 16)),
        border: Border.all(color: c.hairline),
      ),
    );
  }
}

/// One hairline form row (design.md section 6.4): label left, field right.
class _Row extends StatelessWidget {
  final String label;
  final Widget child;
  final VoidCallback? onTap;

  const _Row({required this.label, required this.child, this.onTap});

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

// ---------------------------------------------------------------------------
// Online identification sheet (design.md section 6.4 extension). Loading is
// the design.md section 7 shimmer; errors render as captions; the sheet never
// overwrites a field the user typed into (inline confirm for non-empty
// targets, plus the form-side guard in _applySuggestion).
// ---------------------------------------------------------------------------

Future<void> showIdentificationSheet(
  BuildContext context, {
  required String imagePath,
  required String brand,
  required String subtype,
  required String categoryLabel,
  required Map<IdentificationTarget, String> currentValues,
  required void Function(IdentificationTarget target, String value) onApply,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _IdentificationSheet(
      imagePath: imagePath,
      brand: brand,
      subtype: subtype,
      categoryLabel: categoryLabel,
      currentValues: currentValues,
      onApply: onApply,
    ),
  );
}

class _IdentificationSheet extends StatefulWidget {
  final String imagePath;
  final String brand;
  final String subtype;
  final String categoryLabel;
  final Map<IdentificationTarget, String> currentValues;
  final void Function(IdentificationTarget target, String value) onApply;

  const _IdentificationSheet({
    required this.imagePath,
    required this.brand,
    required this.subtype,
    required this.categoryLabel,
    required this.currentValues,
    required this.onApply,
  });

  @override
  State<_IdentificationSheet> createState() => _IdentificationSheetState();
}

class _IdentificationSheetState extends State<_IdentificationSheet> {
  Future<IdentificationResult>? _future;
  bool _serpKeySet = false;
  bool _visionKeySet = false;

  @override
  void initState() {
    super.initState();
    // One-shot read of the app state without registering a dependency
    // (initState cannot call dependOnInheritedWidgetOfExactType).
    final state =
        context.getInheritedWidgetOfExactType<AppStateScope>()?.notifier;
    _serpKeySet = state?.serpApiKeySet ?? false;
    _visionKeySet = state?.visionApiKeySet ?? false;
    if (_serpKeySet || _visionKeySet) {
      _future = state!.runIdentification(
        imagePath: widget.imagePath,
        categoryLabel: widget.categoryLabel,
        subtype: widget.subtype.isEmpty ? null : widget.subtype,
        brand: widget.brand.isEmpty ? null : widget.brand,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.gutter),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Identify online',
                        style: AppText.title(context)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(AppIcons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.s),
              Flexible(
                child: SingleChildScrollView(
                  child: _body(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    // Setup state: no key yet - explain and offer Settings.
    if (_future == null) {
      return const _NoKeySetup();
    }
    return FutureBuilder<IdentificationResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _loading();
        }
        final result = snapshot.data;
        if (result == null || !result.ok) {
          return _unavailable(result);
        }
        return _results(result);
      },
    );
  }

  /// design.md section 7: shimmer placeholder rows while processing.
  Widget _loading() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < 4; i++) ...[
          const ShimmerPlaceholder(height: 52),
          const SizedBox(height: Spacing.s),
        ],
        Text(
          'Searching the web for this piece...',
          style: AppText.caption(context),
        ),
      ],
    );
  }

  Widget _unavailable(IdentificationResult? result) {
    final lines = (result?.notes.isNotEmpty ?? false)
        ? result!.notes
        : const ['No identification available.'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.s),
            child: Text(line, style: AppText.caption(context)),
          ),
      ],
    );
  }

  Widget _results(IdentificationResult result) {
    final children = <Widget>[];
    if (result.notes.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.m),
          child: Text(result.notes.join(' '), style: AppText.caption(context)),
        ),
      );
    }
    // Matches: title, price in money green, source host (design.md tokens).
    if (result.matches.isNotEmpty) {
      for (final match in result.matches) {
        children.add(_MatchTile(match: match));
      }
      children.add(const SizedBox(height: Spacing.m));
    }
    // Suggestions with Apply affordances.
    final priceApply = result.suggestedPriceValue?.toString() ??
        _parseablePrice(result.suggestedPriceText);
    if (result.suggestedBrand != null) {
      children.add(
        _SuggestionRow(
          label: 'Brand',
          value: result.suggestedBrand!,
          target: IdentificationTarget.brand,
          current: widget.currentValues[IdentificationTarget.brand] ?? '',
          onApply: widget.onApply,
        ),
      );
    }
    if (result.suggestedType != null) {
      children.add(
        _SuggestionRow(
          label: 'Type',
          value: result.suggestedType!,
          target: IdentificationTarget.subtype,
          current: widget.currentValues[IdentificationTarget.subtype] ?? '',
          onApply: widget.onApply,
        ),
      );
    }
    if (priceApply != null) {
      children.add(
        _SuggestionRow(
          label: 'Price',
          value: priceApply,
          target: IdentificationTarget.price,
          current: widget.currentValues[IdentificationTarget.price] ?? '',
          onApply: widget.onApply,
        ),
      );
    }
    if (result.matches.isEmpty &&
        result.suggestedBrand == null &&
        result.suggestedType == null &&
        priceApply == null) {
      children.add(
        Text('No identification available.', style: AppText.caption(context)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  String? _parseablePrice(String? text) {
    if (text == null) return null;
    final value = double.tryParse(text.replaceAll(',', '.'));
    return value?.toString();
  }
}

/// One match row: hairline bottom border, title, price (money green) and the
/// source host as a caption.
class _MatchTile extends StatelessWidget {
  final IdentifiedMatch match;

  const _MatchTile({required this.match});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.m),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            match.title,
            style: AppText.value(context),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (match.priceText != null) ...[
                Text(
                  match.priceText!,
                  style: AppText.value(context, color: c.money),
                ),
                const SizedBox(width: Spacing.m),
              ],
              Expanded(
                child: Text(
                  '${match.source} - ${match.sourceTag == 'serpapi' ? 'SerpApi' : 'Cloud Vision'}',
                  style: AppText.caption(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One suggestion row with an Apply affordance. Applying fills ONLY an empty
/// field; when the field already holds a value the tap expands an inline
/// confirm asking whether to replace the entered value.
class _SuggestionRow extends StatefulWidget {
  final String label;
  final String value;
  final IdentificationTarget target;
  final String current;
  final void Function(IdentificationTarget target, String value) onApply;

  const _SuggestionRow({
    required this.label,
    required this.value,
    required this.target,
    required this.current,
    required this.onApply,
  });

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow> {
  bool _confirming = false;
  bool _applied = false;

  void _apply() {
    setState(() => _applied = true);
    widget.onApply(widget.target, widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final wasEmpty = widget.current.trim().isEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.m),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.label, style: AppText.fieldLabel(context)),
                const SizedBox(height: 2),
                Text(
                  widget.value,
                  style: AppText.value(
                    context,
                    color: widget.target == IdentificationTarget.price
                        ? c.money
                        : null,
                  ),
                ),
                if (_confirming)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.s),
                    child: Text(
                      'Replace "${widget.current}"?',
                      style: AppText.caption(context),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.s),
          if (_applied)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.check, size: 18, color: c.money),
                const SizedBox(width: 4),
                Text('Applied', style: AppText.caption(context)),
              ],
            )
          else if (_confirming)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _apply,
                  child: const Text('Use it'),
                ),
                TextButton(
                  onPressed: () => setState(() => _confirming = false),
                  child: const Text('Keep mine'),
                ),
              ],
            )
          else
            GestureDetector(
              onTap: () {
                if (wasEmpty) {
                  _apply();
                } else {
                  setState(() => _confirming = true);
                }
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: c.hairline),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Apply',
                  style: AppText.button(context).copyWith(fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown when neither key is set: a short setup explanation with a button
/// that opens Settings (pushed as a plain route over this flow).
class _NoKeySetup extends StatelessWidget {
  const _NoKeySetup();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'To look up this piece online, add an API key in Settings. '
          'Free tiers work: SerpApi (serpapi.com - API key page) and/or '
          'Google Cloud Vision (Google Cloud Console - APIs & Services - '
          'Credentials).',
          style: AppText.caption(context),
        ),
        const SizedBox(height: Spacing.m),
        Center(
          child: OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                appRoute(
                  Scaffold(
                    // Back affordance only; the screen itself carries the
                    // "Settings" title.
                    appBar: AppBar(),
                    body: const SettingsScreen(),
                  ),
                ),
              );
            },
            icon: const Icon(AppIcons.settings, size: 20),
            label: const Text('Open Settings'),
          ),
        ),
      ],
    );
  }
}

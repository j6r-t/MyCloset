import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/named_colors.dart';
import '../ui/theme.dart';

/// The named-color picker (design.md section 6.4), rendered as a radial
/// color wheel with an offset loupe: chromatic colors sit hue-ordered on
/// the ring, the neutrals (white/cream/gray/black group) cluster in a
/// small ring around the center disc. Press-drag anywhere to explore - a
/// loupe bubble floats ~80px above the finger, enlarging the hovered
/// color and its name; release commits it. A plain tap on a swatch also
/// selects. The vocabulary stays closed: only the 36 curated names are
/// ever returned, never a free-form hex.
Future<NamedColor?> showNamedColorPicker(
  BuildContext context, {
  NamedColor? current,
}) {
  return showModalBottomSheet<NamedColor>(
    context: context,
    isScrollControlled: true,
    // The wheel's primary gesture IS a drag; the sheet's drag-to-dismiss
    // recognizer would steal vertical drags (and dismiss mid-selection).
    // Cancel is the header close button, which pops null.
    enableDrag: false,
    builder: (_) => _NamedColorPickerSheet(current: current),
  );
}

// ------------------------------------------------------- wheel vocabulary

/// Names that never sit on the chromatic ring - the neutrals cluster in
/// the center of the wheel instead.
const Set<String> _kNeutralNames = {
  'black',
  'charcoal',
  'grey',
  'silver',
  'white',
  'ivory',
  'cream',
  'beige',
};

/// The chromatic colors, hue-ordered clockwise starting from the top.
final List<NamedColor> kWheelChromatic = [
  ...kNamedColors.where((n) => !_kNeutralNames.contains(n.name)),
]..sort((a, b) => _hueOf(a).compareTo(_hueOf(b)));

/// The neutrals in list order (dark to light) for the center cluster.
final List<NamedColor> kWheelNeutrals = [
  for (final n in kNamedColors) if (_kNeutralNames.contains(n.name)) n,
];

/// Opaque swatch color for a stored '#RRGGBB' value. Parsing the bare
/// digits yields 0x00RRGGBB - alpha 0, a fully transparent color - which
/// is why the old grid rendered empty cards; the alpha byte is forced on.
Color swatchColorOf(NamedColor named) {
  final rgb = int.parse(named.hex.substring(1), radix: 16);
  return Color(0xFF000000 | rgb);
}

double _hueOf(NamedColor named) => HSLColor.fromColor(swatchColorOf(named)).hue;

// ---------------------------------------------------------------- layout

const double _kRingSwatch = 44; // finger-sized ring swatches
const double _kNeutralSwatch = 36;
const double _kCenterDisc = 48;
const double _kMaxWheel = 380;
const double _kLoupeWidth = 132;
const double _kLoupeHeight = 122;
const double _kLoupeOffset = 80; // loupe floats this far above the finger

const Key _kLoupeKey = Key('color-loupe');
const Key _kLoupeNameKey = Key('loupe-name');
const Key _kCenterDiscKey = Key('center-disc');

/// One swatch on the wheel: its color, its center inside the wheel square,
/// and its swatch diameter (ring vs center cluster).
class _WheelEntry {
  final NamedColor named;
  final Offset center;
  final double size;
  final bool neutral;

  const _WheelEntry(this.named, this.center, this.size, this.neutral);
}

/// Sheet host: title row with cancel (pop null) and the wheel; a commit
/// pops the sheet with the named color, same contract as the old grid.
class _NamedColorPickerSheet extends StatelessWidget {
  const _NamedColorPickerSheet({this.current});

  final NamedColor? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.gutter,
          Spacing.m,
          Spacing.gutter,
          Spacing.m,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Color', style: AppText.title(context)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(AppIcons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: Spacing.m),
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final diameter = math.min(
                    math.min(constraints.maxWidth, constraints.maxHeight),
                    _kMaxWheel,
                  );
                  return _ColorWheel(
                    diameter: diameter,
                    current: current,
                    onCommit: (named) => Navigator.of(context).pop(named),
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

class _ColorWheel extends StatefulWidget {
  const _ColorWheel({
    required this.diameter,
    required this.onCommit,
    this.current,
  });

  final double diameter;
  final NamedColor? current;
  final ValueChanged<NamedColor> onCommit;

  @override
  State<_ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<_ColorWheel> {
  late final List<_WheelEntry> _entries = _buildEntries(widget.diameter);

  /// Finger position during a drag (wheel-local); null when not dragging.
  Offset? _pointer;

  /// The swatch currently under the finger during a drag.
  NamedColor? _hover;

  bool get _dragging => _pointer != null;

  /// Chromatic ring on the outside, neutrals on an inner ring around the
  /// center disc.
  List<_WheelEntry> _buildEntries(double diameter) {
    final wheelCenter = Offset(diameter / 2, diameter / 2);
    final ringRadius = diameter / 2 - _kRingSwatch / 2;
    final entries = <_WheelEntry>[];

    final chromatic = kWheelChromatic;
    for (var i = 0; i < chromatic.length; i++) {
      final angle = -math.pi / 2 + 2 * math.pi * i / chromatic.length;
      entries.add(_WheelEntry(
        chromatic[i],
        wheelCenter +
            Offset(math.cos(angle), math.sin(angle)) * ringRadius,
        _kRingSwatch,
        false,
      ));
    }

    final neutrals = kWheelNeutrals;
    final neutralRadius = ringRadius * 0.45;
    for (var i = 0; i < neutrals.length; i++) {
      // Offset half a step so 'white' does not sit exactly behind 'scarlet'.
      final angle = -math.pi / 2 +
          math.pi / neutrals.length +
          2 * math.pi * i / neutrals.length;
      entries.add(_WheelEntry(
        neutrals[i],
        wheelCenter +
            Offset(math.cos(angle), math.sin(angle)) * neutralRadius,
        _kNeutralSwatch,
        true,
      ));
    }
    return entries;
  }

  /// Nearest swatch whose center is within slop of [local]; the loupe
  /// disambiguates overlaps, so nearest-center is the right resolution.
  NamedColor? _hitAt(Offset local) {
    NamedColor? best;
    var bestDistance = double.infinity;
    for (final entry in _entries) {
      final distance = (local - entry.center).distance;
      final radius = entry.size / 2 + 6;
      if (distance <= radius && distance < bestDistance) {
        bestDistance = distance;
        best = entry.named;
      }
    }
    return best;
  }

  void _onTapUp(TapUpDetails details) {
    final hit = _hitAt(details.localPosition);
    if (hit != null) widget.onCommit(hit);
  }

  void _onDragMove(Offset local) {
    final hit = _hitAt(local);
    if (hit != null && !identical(hit, _hover)) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _pointer = local;
      _hover = hit;
    });
  }

  void _onDragEnd() {
    final hover = _hover;
    if (hover != null) {
      widget.onCommit(hover); // commits and pops; state dies with the sheet
    } else {
      setState(() => _pointer = null);
    }
  }

  void _onDragCancel() {
    setState(() {
      _pointer = null;
      _hover = null;
    });
  }

  /// Loupe top-left, offset above the finger and clamped inside the wheel.
  Offset _loupeTopLeft() {
    final d = widget.diameter;
    final p = _pointer!;
    final left = (p.dx - _kLoupeWidth / 2).clamp(0.0, d - _kLoupeWidth);
    final top =
        (p.dy - _kLoupeOffset - _kLoupeHeight).clamp(0.0, d - _kLoupeHeight);
    return Offset(left, top);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    /// Hover during a drag, otherwise the committed selection; drives the
    /// marked ring, the center disc and the readout row.
    final live = _hover ?? widget.current;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.diameter,
          height: widget.diameter,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onPanStart: (details) => _onDragMove(details.localPosition),
            onPanUpdate: (details) => _onDragMove(details.localPosition),
            onPanEnd: (_) => _onDragEnd(),
            onPanCancel: _onDragCancel,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Center disc: the current selection at a glance.
                Center(
                  child: Container(
                    key: _kCenterDiscKey,
                    width: _kCenterDisc,
                    height: _kCenterDisc,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.current == null
                          ? c.tile
                          : swatchColorOf(widget.current!),
                      border: Border.all(color: c.hairline),
                    ),
                  ),
                ),
                for (final entry in _entries)
                  Positioned(
                    left: entry.center.dx - entry.size / 2,
                    top: entry.center.dy - entry.size / 2,
                    child: Container(
                      key: Key('swatch-${entry.named.name}'),
                      width: entry.size,
                      height: entry.size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: swatchColorOf(entry.named),
                        border: Border.all(
                          color: identical(live, entry.named)
                              ? c.ink
                              : c.hairline,
                          width: identical(live, entry.named) ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
                if (_dragging && _hover != null)
                  Positioned(
                    left: _loupeTopLeft().dx,
                    top: _loupeTopLeft().dy,
                    child: _buildLoupe(c),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.s),
        // Readout: dot + name for the live selection (hover while dragging).
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: live == null ? c.tile : swatchColorOf(live),
                border: Border.all(color: c.hairline),
              ),
            ),
            const SizedBox(width: Spacing.s),
            Text(
              live?.name ?? 'none',
              style: AppText.caption(context),
            ),
          ],
        ),
      ],
    );
  }

  /// The magnifier bubble: hovered color enlarged to 72px, name beneath,
  /// surface fill + hairline border + soft shadow so it reads on any
  /// background in either theme.
  Widget _buildLoupe(AppColors c) {
    final hover = _hover!;
    return Container(
      key: _kLoupeKey,
      width: _kLoupeWidth,
      height: _kLoupeHeight,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.hairline),
        boxShadow: const [
          BoxShadow(
            color: Color(0x29000000),
            blurRadius: 20,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: swatchColorOf(hover),
              border: Border.all(color: c.hairline),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hover.name,
            key: _kLoupeNameKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppText.caption(context),
          ),
        ],
      ),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/named_colors.dart';
import '../services/color_math.dart';
import '../ui/theme.dart';

/// The named-color picker, rendered as a continuous HSV color wheel:
/// hue sweeps clockwise around the circle (red at 12 o'clock), saturation
/// grows radially from pure white in the center to fully saturated hues at
/// the rim. Press-drag anywhere and a circular color loupe floats above the
/// finger - a disc of the exact color under the finger, fine white border,
/// soft drop shadow - naming the curated color the wheel will save; release
/// commits it. A plain tap on the wheel commits too.
///
/// The vocabulary stays closed: the picked hue/saturation is snapped to the
/// nearest of the 36 curated names with [snapToNamedColor] (CIELAB, same
/// mapping the extraction pipeline uses), so the suggestion engine only ever
/// sees known colors - the wheel never returns free-form hex.
///
/// Brightness (HSV value): the wheel itself is a 2D hue/saturation surface
/// rendered at value 1.0, exactly as designed. The quiet brightness slider
/// beneath it dims the same cached surface (a plain black source-over
/// overlay, which multiplies every channel by the value) so the darker
/// curated names - navy, charcoal, black, chocolate - stay reachable.
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

// ------------------------------------------------------------ wheel surface

/// Brightness applied to wheel picks when the sheet opens. Without a
/// current color the wheel reads exactly as designed - white center fading
/// into fully saturated hues at the rim; with one, it starts at that
/// color's own brightness.
const double kWheelMaxValue = 1.0;

/// Brightness floor for the slider: low enough to reach black/charcoal,
/// high enough that the wheel never goes fully dark.
const double kWheelMinValue = 0.15;

/// Wheel geometry, shared by the gesture mapping, the marker layout and the
/// tests: hue 0 (red) sits at 12 o'clock and sweeps clockwise; saturation
/// grows linearly from the white center (0) to the rim (1). [local] is in
/// the wheel square's coordinates (0..[size]).
({double hue, double saturation}) wheelHsvAt(Offset local, double size) {
  final v = local - Offset(size / 2, size / 2);
  final a = math.atan2(v.dy, v.dx) + math.pi / 2;
  final hue = (a < 0 ? a + 2 * math.pi : a) / (2 * math.pi) * 360.0;
  final saturation = (v.distance / (size / 2)).clamp(0.0, 1.0);
  return (hue: hue, saturation: saturation);
}

/// The inverse of [wheelHsvAt]: the wheel-square point for a hue/saturation.
/// [rimInset] pulls the point in from the rim (used so the selection ring
/// stays inside the hairline border).
Offset wheelPointForHsv(
  double hue,
  double saturation,
  double size, {
  double rimInset = 0,
}) {
  final radius = math.max(0.0, size / 2 - rimInset) * saturation.clamp(0.0, 1.0);
  final angle = hue / 360.0 * 2 * math.pi - math.pi / 2;
  return Offset(size / 2, size / 2) +
      Offset(math.cos(angle), math.sin(angle)) * radius;
}

/// The exact color under a wheel point at [value] brightness.
Color wheelColorAt(Offset local, double size, double value) {
  final hsv = wheelHsvAt(local, size);
  return HSVColor.fromAHSV(1.0, hsv.hue, hsv.saturation, value).toColor();
}

String _hexOf(Color color) => rgbToHex(
      (color.r * 255).round(),
      (color.g * 255).round(),
      (color.b * 255).round(),
    );

/// Opaque color for a stored '#RRGGBB' value. Parsing the bare digits yields
/// 0x00RRGGBB - alpha 0 - so the alpha byte is forced on.
Color _swatchColorOf(NamedColor named) {
  final rgb = int.parse(named.hex.substring(1), radix: 16);
  return Color(0xFF000000 | rgb);
}

/// The wheel surface: a full-saturation hue sweep with the white center
/// faded in radially. At value 1.0, HSV(h, s, 1) is exactly the linear mix
/// of white and the pure hue, so an alpha radial gradient over the sweep is
/// mathematically the HSV surface - no per-pixel work anywhere; both
/// gradients rasterize once on the GPU behind a repaint boundary and
/// dragging only rebuilds the overlays above.
class _WheelSurfacePainter extends CustomPainter {
  const _WheelSurfacePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final bounds = Offset.zero & size;

    final sweep = Paint()
      // Full-saturation hue stops every 15 degrees - exactly
      // HSVColor.fromAHSV(1, i * 15, 1, 1).toColor(), const-friendly.
      ..shader = const SweepGradient(
        center: Alignment.center,
        startAngle: -math.pi / 2,
        endAngle: -math.pi / 2 + 2 * math.pi,
        colors: [
          Color(0xFFFF0000), Color(0xFFFF4000), Color(0xFFFF8000),
          Color(0xFFFFBF00), Color(0xFFFFFF00), Color(0xFFBFFF00),
          Color(0xFF80FF00), Color(0xFF40FF00), Color(0xFF00FF00),
          Color(0xFF00FF40), Color(0xFF00FF80), Color(0xFF00FFBF),
          Color(0xFF00FFFF), Color(0xFF00BFFF), Color(0xFF0080FF),
          Color(0xFF0040FF), Color(0xFF0000FF), Color(0xFF4000FF),
          Color(0xFF8000FF), Color(0xFFBF00FF), Color(0xFFFF00FF),
          Color(0xFFFF00BF), Color(0xFFFF0080), Color(0xFFFF0040),
          Color(0xFFFF0000),
        ],
      ).createShader(bounds);
    final fade = Paint()
      ..shader = const RadialGradient(
        center: Alignment.center,
        radius: 0.5,
        colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
      ).createShader(bounds);

    canvas
      ..save()
      ..clipPath(
        Path()
          ..addOval(
            Rect.fromCircle(center: center, radius: size.width / 2),
          ),
      )
      ..drawRect(bounds, sweep)
      ..drawRect(bounds, fade)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _WheelSurfacePainter oldDelegate) => false;
}

// ---------------------------------------------------------------- layout

const double _kMaxWheel = 380;
const double _kLoupeDisc = 84;
const double _kLoupeGap = 6;
const double _kLoupeChip = 26;
const double _kLoupeBlockHeight = _kLoupeDisc + _kLoupeGap + _kLoupeChip;
const double _kLoupeOffset = 80; // the loupe floats this far above the finger
const double _kMarker = 30;
const double _kMarkerInset = _kMarker / 2 + 2; // keeps the ring inside the rim

const Key _kWheelKey = Key('color-wheel');
const Key _kLoupeKey = Key('color-loupe');
const Key _kLoupeDiscKey = Key('loupe-disc');
const Key _kLoupeNameKey = Key('loupe-name');
const Key _kMarkerKey = Key('selection-marker');
const Key _kSliderKey = Key('value-slider');
const Key _kReadoutKey = Key('wheel-readout');

/// Sheet host: title row with cancel (pop null), the wheel, the brightness
/// slider and the live readout; a commit pops the sheet with the named
/// color.
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
  /// Finger position during a drag (wheel-local); null when not dragging.
  Offset? _pointer;

  /// Brightness (HSV value) for picks. Starts at the current color's own
  /// brightness so the readout names exactly the selection the sheet opened
  /// with; otherwise full - see the header comment.
  late double _value = _initialValue();

  /// Last snapped name during the current drag, for the haptic tick.
  String? _lastSnapped;

  double _initialValue() {
    final current = widget.current;
    if (current == null) return kWheelMaxValue;
    return HSVColor.fromColor(_swatchColorOf(current))
        .value
        .clamp(kWheelMinValue, kWheelMaxValue);
  }

  bool get _dragging => _pointer != null;

  /// The hue/saturation the picker is live on: the finger during a drag,
  /// otherwise the opened selection. Null with no selection and no drag.
  ({double hue, double saturation})? get _liveHsv {
    final pointer = _pointer;
    if (pointer != null) return wheelHsvAt(pointer, widget.diameter);
    final current = widget.current;
    if (current == null) return null;
    final hsv = HSVColor.fromColor(_swatchColorOf(current));
    return (hue: hsv.hue, saturation: hsv.saturation);
  }

  /// The exact live color, at the slider's brightness.
  Color get _liveColor {
    final hsv = _liveHsv!;
    return HSVColor.fromAHSV(1.0, hsv.hue, hsv.saturation, _value).toColor();
  }

  /// The curated name a commit would save right now - the wheel never
  /// returns free-form colors, only the nearest of [kNamedColors].
  NamedColor? get _liveNamed {
    if (_liveHsv == null) return null;
    return snapToNamedColor(_hexOf(_liveColor));
  }

  NamedColor _snapAt(Offset local) =>
      snapToNamedColor(_hexOf(wheelColorAt(local, widget.diameter, _value)))!;

  /// Drags track the finger even past the rim: the point clamps onto the
  /// circle so the loupe never drops mid-gesture.
  Offset _clampIntoWheel(Offset local) {
    final center = Offset(widget.diameter / 2, widget.diameter / 2);
    final v = local - center;
    final radius = widget.diameter / 2;
    if (v.distance <= radius || v.distance == 0) return local;
    return center + (v / v.distance) * radius;
  }

  void _onTapUp(TapUpDetails details) {
    // Corner taps outside the circle do nothing; a tap on the wheel commits
    // the named color under the finger.
    final v = details.localPosition -
        Offset(widget.diameter / 2, widget.diameter / 2);
    if (v.distance > widget.diameter / 2) return;
    widget.onCommit(_snapAt(details.localPosition));
  }

  void _onDragMove(Offset rawLocal) {
    final local = _clampIntoWheel(rawLocal);
    final named = _snapAt(local);
    if (named.name != _lastSnapped) {
      _lastSnapped = named.name;
      HapticFeedback.selectionClick();
    }
    setState(() => _pointer = local);
  }

  void _onDragEnd() {
    final pointer = _pointer;
    if (pointer != null) {
      widget.onCommit(_snapAt(pointer)); // commits and pops; state dies here
    }
  }

  void _onDragCancel() {
    setState(() {
      _pointer = null;
      _lastSnapped = null;
    });
  }

  void _setValueAt(double dx, double width) {
    final t = (width <= 0 ? 0.0 : dx / width).clamp(0.0, 1.0);
    setState(() {
      _value = kWheelMinValue + t * (kWheelMaxValue - kWheelMinValue);
    });
  }

  /// Loupe top-left, offset above the finger and clamped inside the wheel
  /// square.
  Offset _loupeTopLeft() {
    final d = widget.diameter;
    final p = _pointer!;
    final left = (p.dx - _kLoupeDisc / 2).clamp(0.0, d - _kLoupeDisc);
    final top =
        (p.dy - _kLoupeOffset - _kLoupeBlockHeight).clamp(0.0, d - _kLoupeBlockHeight);
    return Offset(left, top);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final d = widget.diameter;
    final liveHsv = _liveHsv;
    final liveNamed = _liveNamed;
    final markerCenter = liveHsv == null
        ? null
        : wheelPointForHsv(
            liveHsv.hue,
            liveHsv.saturation,
            d,
            rimInset: _kMarkerInset,
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: d,
          height: d,
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
                // The wheel surface, painted once and cached; dragging
                // never repaints it.
                RepaintBoundary(
                  child: ClipOval(
                    key: _kWheelKey,
                    child: CustomPaint(
                      size: Size.square(d),
                      painter: const _WheelSurfacePainter(),
                    ),
                  ),
                ),
                // Brightness below full: a black source-over overlay at
                // alpha (1 - v) multiplies every channel by exactly v -
                // the HSV value step - with no saveLayer.
                if (_value < kWheelMaxValue)
                  Positioned.fill(
                    child: ClipOval(
                      child: ColoredBox(
                        color: Color.fromRGBO(0, 0, 0, 1 - _value),
                      ),
                    ),
                  ),
                // Crisp hairline rim.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.hairline),
                    ),
                  ),
                ),
                // Selection ring: the finger while dragging, otherwise the
                // opened selection.
                if (markerCenter != null)
                  Positioned(
                    left: markerCenter.dx - _kMarker / 2,
                    top: markerCenter.dy - _kMarker / 2,
                    child: Container(
                      key: _kMarkerKey,
                      width: _kMarker,
                      height: _kMarker,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(color: Color(0xFFFFFFFF), width: 2.5),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 2,
                            offset: Offset(0, 1),
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_dragging)
                  Positioned(
                    left: _loupeTopLeft().dx,
                    top: _loupeTopLeft().dy,
                    child: _buildLoupe(context, c),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.m),
        _buildValueSlider(context, c),
        const SizedBox(height: Spacing.m),
        // Readout: the exact live color and the curated name a commit
        // would save.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: liveNamed == null ? c.tile : _liveColor,
                border: Border.all(color: c.hairline),
              ),
            ),
            const SizedBox(width: Spacing.s),
            Text(
              liveNamed?.name ?? 'Pick a color',
              key: _kReadoutKey,
              style: AppText.caption(context),
            ),
          ],
        ),
      ],
    );
  }

  /// The floating loupe: a disc of the exact color under the finger, fine
  /// white border, soft drop shadow (the one allowed shadow), with the
  /// curated name it snaps to in a quiet chip beneath.
  Widget _buildLoupe(BuildContext context, AppColors c) {
    return Column(
      key: _kLoupeKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: _kLoupeDiscKey,
          width: _kLoupeDisc,
          height: _kLoupeDisc,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _liveColor,
            border: Border.all(color: const Color(0xFFFFFFFF), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x2E000000),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
        ),
        const SizedBox(height: _kLoupeGap),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: c.hairline),
          ),
          child: Text(
            _liveNamed!.name,
            key: _kLoupeNameKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption(context),
          ),
        ),
      ],
    );
  }

  /// Minimal brightness slider: a hairline track with an ink knob, no
  /// chrome. Adjusts the brightness the next wheel tap or drag commits; it
  /// never commits on its own - the wheel is the picker.
  Widget _buildValueSlider(BuildContext context, AppColors c) {
    return Row(
      children: [
        Text('Brightness', style: AppText.caption(context)),
        const SizedBox(width: Spacing.m),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final t =
                  (_value - kWheelMinValue) / (kWheelMaxValue - kWheelMinValue);
              return GestureDetector(
                key: _kSliderKey,
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => _setValueAt(details.localPosition.dx, width),
                onHorizontalDragStart: (details) =>
                    _setValueAt(details.localPosition.dx, width),
                onHorizontalDragUpdate: (details) =>
                    _setValueAt(details.localPosition.dx, width),
                child: SizedBox(
                  height: 28,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Center(
                        child: Container(
                          height: 2,
                          width: width,
                          color: c.hairline,
                        ),
                      ),
                      Positioned(
                        left: (width - 16) * t.clamp(0.0, 1.0),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.ink,
                            border: Border.all(color: c.surface, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x1F000000),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/brush_controls.dart';
import 'capture_screen.dart';
import 'details_form_screen.dart';

/// Screen 3 - Add item, cutout review. The result on a `tile` background;
/// actions Retake / Eraser / Continue (design.md section 6.3).
///
/// Graceful fallback: when segmentation produced no cutout
/// ([draftCutoutPath] is null - the current stub service always returns
/// null, backend.md section 3.3), the original photo is shown, the eraser is
/// disabled with a quiet explanation, and Continue proceeds with the
/// original as the item image.
class CutoutReviewScreen extends StatefulWidget {
  final String draftOriginalPath;

  /// Draft RGBA cutout PNG path, or null when segmentation fell back.
  final String? draftCutoutPath;

  const CutoutReviewScreen({
    super.key,
    required this.draftOriginalPath,
    this.draftCutoutPath,
  });

  @override
  State<CutoutReviewScreen> createState() => _CutoutReviewScreenState();
}

/// One eraser stroke: points and radius in image coordinates, plus the
/// erase strength ([opacity], 0.0-1.0) the stroke was drawn with.
class _EraseStroke {
  final List<Offset> points;
  final double radius;
  final double opacity;

  _EraseStroke(this.points, this.radius, {required this.opacity});
}

/// Which brush control is currently being dragged, if any.
enum _IndicatorMode { none, size, opacity }

class _CutoutReviewScreenState extends State<CutoutReviewScreen> {
  /// The working cutout raster: the original cutout with EVERY committed
  /// stroke already composited in. Single source of truth - strokes
  /// accumulate here permanently, so any number of brush passes survives.
  ui.Image? _image;

  /// Working-image snapshots taken just before each committed stroke, for
  /// undo (backend.md section 3.4: effectively "last 5"). Non-empty means
  /// there are outstanding edits to persist.
  final List<ui.Image> _undoStack = [];
  static const int maxUndoDepth = 5;

  /// Serializes stroke commits so overlapping pointer-ups can never
  /// composite against a stale working image.
  Future<void> _commitQueue = Future.value();

  /// Stroke currently being drawn, for live preview.
  _EraseStroke? _activeStroke;

  /// Brush thickness at display scale, in screen pixels across (the stamp
  /// diameter the user sees). Stored in image coordinates as
  /// size / 2 / [_scale].
  double _brushSizePx = 40;

  /// Erase strength in percent (10-100). The stamp's alpha.
  int _brushOpacityPct = 100;

  /// The control currently dragged - drives the indicator ring.
  _IndicatorMode _indicatorMode = _IndicatorMode.none;

  /// Display rect of the garment image inside the canvas area (set during
  /// layout); the indicator anchor is clamped to it.
  Rect _displayRect = Rect.zero;

  /// Last-known touch position in canvas-local coordinates, or null before
  /// the first touch (the indicator then sits at the canvas center).
  Offset? _indicatorAnchor;

  /// Display mapping (set during layout).
  double _scale = 1;
  Offset _imageOrigin = Offset.zero;

  bool get _hasCutout => widget.draftCutoutPath != null;
  bool get _erasing => _showEraser && _hasCutout;
  bool _showEraser = false;
  bool _busy = false;

  /// Blocks pops (system back included) until the drafts are cleaned up;
  /// flipped before the programmatic pop so the PopScope handler lets it
  /// through.
  bool _canPop = false;

  /// Re-entry guard for the PopScope handler.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    if (!_hasCutout) return;
    try {
      final bytes = await File(widget.draftCutoutPath!).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _image = frame.image;
        });
      }
    } catch (e) {
      debugPrint('Could not load cutout for review: $e');
    }
  }

  // ---------------------------------------------------------------- eraser

  Offset _toImage(Offset local) => (local - _imageOrigin) / _scale;

  /// Stamp radius in image pixels for the current brush thickness: the
  /// slider is in display pixels across, so the same diameter appears on
  /// screen (and in the indicator ring) as the stamp covers.
  double _brushRadius() => (_brushSizePx / 2) / _scale;

  /// Anchors the indicator ring at the last-known touch position, falling
  /// back to the garment-image center before the first touch.
  void _startIndicator(_IndicatorMode mode) {
    setState(() {
      _indicatorMode = mode;
      _indicatorAnchor ??= _displayRect.center;
    });
  }

  void _moveIndicatorTo(Offset local) {
    if (_displayRect == Rect.zero) return;
    setState(() {
      _indicatorAnchor = Offset(
        local.dx.clamp(_displayRect.left, _displayRect.right),
        local.dy.clamp(_displayRect.top, _displayRect.bottom),
      );
    });
  }

  void _onPanStart(DragStartDetails d) {
    if (!_erasing || _image == null) return;
    setState(() {
      _activeStroke = _EraseStroke(
        [_toImage(d.localPosition)],
        _brushRadius(),
        opacity: _brushOpacityPct / 100,
      );
    });
    _moveIndicatorTo(d.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_erasing || _activeStroke == null) return;
    setState(() {
      _activeStroke!.points.add(_toImage(d.localPosition));
    });
    _moveIndicatorTo(d.localPosition);
  }

  Future<void> _onPanEnd(DragEndDetails d) async {
    final stroke = _activeStroke;
    if (stroke == null || _image == null) return;
    setState(() => _activeStroke = null);
    _commitStroke(stroke);
  }

  /// Commits a finished stroke into the working image permanently: a
  /// snapshot of the current working image is pushed for undo, then the
  /// stroke is composited into a fresh raster that becomes the working
  /// image. Commits run sequentially through [_commitQueue] so a fast
  /// second stroke can never composite against a stale base. No re-running
  /// the model (backend.md section 3.4).
  void _commitStroke(_EraseStroke stroke) {
    _commitQueue = _commitQueue.then((_) async {
      final base = _image;
      if (base == null || !mounted) return;
      final composited = await _compositeStroke(base, stroke);
      if (!mounted) return;
      setState(() {
        _undoStack.add(base);
        // Cap the undo window at 5 snapshots (backend.md section 3.4:
        // "last 5"). Older snapshots are dropped, but their strokes stay
        // in the working image - only undo depth shrinks.
        while (_undoStack.length > maxUndoDepth) {
          _undoStack.removeAt(0);
        }
        _image = composited;
      });
    });
  }

  /// Composites one stroke (dstOut hard stamps at its stored opacity) onto
  /// [base] into a fresh raster.
  Future<ui.Image> _compositeStroke(ui.Image base, _EraseStroke stroke) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(base, Offset.zero, Paint());

    final erase = Paint()
      ..blendMode = BlendMode.dstOut
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      // Hard felt-tip edge: no maskFilter, only anti-aliasing. For dstOut
      // the color is irrelevant - only the alpha carries the erase strength.
      ..maskFilter = null;

    erase.color = Colors.black.withValues(alpha: stroke.opacity);
    if (stroke.points.length == 1) {
      canvas.drawCircle(stroke.points.first, stroke.radius, erase);
    } else {
      final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final p in stroke.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      erase.strokeWidth = stroke.radius * 2;
      canvas.drawPath(path, erase);
    }
    return recorder.endRecording().toImage(base.width, base.height);
  }

  /// Undo restores the working-image snapshot taken before the last
  /// committed stroke. Outstanding edits are exactly the snapshots on the
  /// stack: undoing all of them leaves nothing to persist.
  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    setState(() => _image = _undoStack.removeLast());
  }

  // --------------------------------------------------------------- actions

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      String? cutoutPath = widget.draftCutoutPath;
      if (_hasCutout && _image != null && _undoStack.isNotEmpty) {
        // Persist the erased alpha back to the draft cutout file.
        final data = await _image!.toByteData(format: ui.ImageByteFormat.png);
        if (data != null) {
          await File(
            widget.draftCutoutPath!,
          ).writeAsBytes(data.buffer.asUint8List(), flush: true);
          cutoutPath = widget.draftCutoutPath;
        }
      }
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        appRoute(
          DetailsFormScreen(
            draftOriginalPath: widget.draftOriginalPath,
            draftCutoutPath: cutoutPath,
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save the erase: $e')),
      );
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Exit the flow: drafts are discarded (userFlow.md flow 2, step 5).
  /// Runs for both the back button and the system back gesture via PopScope.
  Future<void> _discardAndExit() async {
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

  /// Retake: back to the capture step, nothing saved (userFlow.md flow 2,
  /// step 3). Replaces this screen with a fresh capture.
  Future<void> _retake() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppStateScope.of(context).storage.clearTmp();
      if (!mounted) return;
      navigator.pushReplacement(appRoute(const CaptureScreen()));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not clean up the draft: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_leaving) _discardAndExit();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(AppIcons.back),
            onPressed: _discardAndExit,
          ),
          title: const Text('Review the cutout'),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_hasCutout)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.gutter,
                    Spacing.s,
                    Spacing.gutter,
                    0,
                  ),
                  child: Text(
                    'Background removal is not available yet - the original '
                    'photo will be saved instead.',
                    style: AppText.caption(context),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.gutter),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      Widget content;
                      if (_hasCutout && _image != null) {
                        final img = _image!;
                        _scale = math.min(
                          constraints.biggest.width / img.width,
                          constraints.biggest.height / img.height,
                        );
                        final dispW = img.width * _scale;
                        final dispH = img.height * _scale;
                        _imageOrigin = Offset(
                          (constraints.biggest.width - dispW) / 2,
                          (constraints.biggest.height - dispH) / 2,
                        );
                        _displayRect = Rect.fromLTWH(
                          _imageOrigin.dx,
                          _imageOrigin.dy,
                          dispW,
                          dispH,
                        );
                        final mode = _indicatorMode;
                        final showIndicator =
                            mode != _IndicatorMode.none &&
                            _displayRect != Rect.zero;
                        content = GestureDetector(
                          onPanStart: _onPanStart,
                          onPanUpdate: _onPanUpdate,
                          onPanEnd: _onPanEnd,
                          child: Stack(
                            children: [
                              Positioned(
                                left: _imageOrigin.dx,
                                top: _imageOrigin.dy,
                                width: dispW,
                                height: dispH,
                                child: CustomPaint(
                                  painter: _CutoutPainter(
                                    image: _image!,
                                    activeStroke: _activeStroke,
                                    tileColor: c.tile,
                                  ),
                                ),
                              ),
                              // Live brush indicator while a thickness or
                              // opacity control is dragged: the ring's
                              // diameter equals the brush size on screen
                              // (same scale mapping as the stamp), at the
                              // last-known touch position.
                              if (showIndicator)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _BrushIndicatorPainter(
                                        center:
                                            _indicatorAnchor ??
                                            _displayRect.center,
                                        diameter: _brushSizePx,
                                        fillAlpha:
                                            mode == _IndicatorMode.opacity
                                            ? _brushOpacityPct / 100
                                            : 0,
                                        ink: c.ink,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      } else if (_hasCutout) {
                        // Cutout still decoding.
                        content = Container(
                          decoration: BoxDecoration(
                            color: c.tile,
                            borderRadius: BorderRadius.circular(16),
                          ),
                        );
                      } else {
                        content = Container(
                          decoration: BoxDecoration(
                            color: c.tile,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.all(Spacing.m),
                          child: Image.file(
                            File(widget.draftOriginalPath),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const SizedBox(),
                          ),
                        );
                      }
                      return content;
                    },
                  ),
                ),
              ),
              // Eraser brush controls: thickness + opacity. Dragging either
              // shows the live indicator ring on the canvas.
              if (_showEraser && _hasCutout)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.gutter,
                    0,
                    Spacing.gutter,
                    Spacing.s,
                  ),
                  child: Column(
                    children: [
                      BrushControlRow(
                        icon: AppIcons.brush,
                        label: 'Brush size',
                        value: _brushSizePx,
                        min: 8,
                        max: 64,
                        divisions: 28,
                        caption: '${_brushSizePx.round()}',
                        onChangeStart: () =>
                            _startIndicator(_IndicatorMode.size),
                        onChanged: (v) => setState(() {
                          _brushSizePx = v;
                        }),
                        onChangeEnd: () => setState(() {
                          _indicatorMode = _IndicatorMode.none;
                        }),
                      ),
                      BrushControlRow(
                        icon: Symbols.opacity,
                        label: 'Eraser opacity',
                        value: _brushOpacityPct.toDouble(),
                        min: 10,
                        max: 100,
                        divisions: 90,
                        caption: '$_brushOpacityPct%',
                        onChangeStart: () =>
                            _startIndicator(_IndicatorMode.opacity),
                        onChanged: (v) => setState(() {
                          _brushOpacityPct = v.round();
                        }),
                        onChangeEnd: () => setState(() {
                          _indicatorMode = _IndicatorMode.none;
                        }),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.gutter,
                  0,
                  Spacing.gutter,
                  Spacing.m,
                ),
                child: Row(
                  children: [
                    // Retake: back to the capture step; nothing is saved yet.
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _retake,
                        child: Text('Retake', style: AppText.button(context)),
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    // Eraser toggle (design.md section 4 icon set: brush).
                    Tooltip(
                      message: _hasCutout
                          ? (_erasing ? 'Eraser on' : 'Eraser')
                          : 'Eraser needs a cutout',
                      child: GestureDetector(
                        onTap: _hasCutout
                            ? () => setState(() => _showEraser = !_showEraser)
                            : null,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _erasing ? c.ink : c.hairline,
                              width: _erasing ? 1.5 : 1,
                            ),
                            color: _erasing ? c.tile : Colors.transparent,
                          ),
                          child: Icon(
                            AppIcons.brush,
                            size: 20,
                            color: _hasCutout
                                ? (_erasing ? c.ink : c.inkSecondary)
                                : c.hairline,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    // Undo while committed strokes exist (last 5).
                    Tooltip(
                      message: 'Undo',
                      child: GestureDetector(
                        onTap: _undoStack.isEmpty ? null : _undo,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _undoStack.isEmpty
                                  ? c.hairline
                                  : c.inkSecondary,
                            ),
                          ),
                          child: Icon(
                            AppIcons.undo,
                            size: 20,
                            color: _undoStack.isEmpty ? c.hairline : c.ink,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : _continue,
                        // Ink fill pairs with white content (design.md
                        // section 1); the disabled tile fill pairs with
                        // ink-secondary.
                        child: Text(
                          'Continue',
                          style: AppText.button(
                            context,
                            color: _busy ? c.inkSecondary : c.bg,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the eraser canvas: the `tile` gray backdrop first (so erased
/// transparent areas read as gray, not white - design.md section 6.3),
/// then the cutout and the in-progress eraser stroke. Strokes erase alpha
/// (dstOut) with a hard round stamp - anti-aliased, no blur feathering
/// (backend.md section 3.4).
class _CutoutPainter extends CustomPainter {
  final ui.Image image;
  final _EraseStroke? activeStroke;
  final Color tileColor;

  _CutoutPainter({
    required this.image,
    required this.tileColor,
    this.activeStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The gray canvas behind the garment: same tile token as the hero
    // cards, rounded like them.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)),
      Paint()..color = tileColor,
    );
    canvas.saveLayer(null, Paint());
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final erase = Paint()
      ..blendMode = BlendMode.dstOut
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = null;

    final stroke = activeStroke;
    if (stroke != null) {
      erase.color = Colors.black.withValues(alpha: stroke.opacity);
      erase.strokeWidth = stroke.radius * 2;
      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, stroke.radius, erase);
      } else {
        final path = Path()
          ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
        for (final p in stroke.points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, erase);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CutoutPainter old) =>
      old.image != image || old.activeStroke != activeStroke;
}

/// The live brush indicator ring shown while a thickness or opacity control
/// is dragged. Drawn in the canvas' local coordinates; [diameter] is in
/// display pixels, matching exactly what the stamp covers on screen
/// (radius * 2 * scale). Size mode is a bare ring; opacity mode fills the
/// interior with black at the current erase alpha.
class _BrushIndicatorPainter extends CustomPainter {
  final Offset center;
  final double diameter;

  /// 0.0-1.0; 0 renders no fill (thickness mode).
  final double fillAlpha;

  final Color ink;

  _BrushIndicatorPainter({
    required this.center,
    required this.diameter,
    required this.fillAlpha,
    required this.ink,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = diameter / 2;
    if (fillAlpha > 0) {
      canvas.drawCircle(
        center,
        r,
        Paint()..color = Colors.black.withValues(alpha: fillAlpha),
      );
    }
    // Subtle white inner/outer outline so the ring reads on any background,
    // then the ink hairline ring on top.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ink,
    );
  }

  @override
  bool shouldRepaint(_BrushIndicatorPainter old) =>
      old.center != center ||
      old.diameter != diameter ||
      old.fillAlpha != fillAlpha;
}

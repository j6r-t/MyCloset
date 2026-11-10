import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ui/app_state.dart';
import '../ui/theme.dart';
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

/// One eraser stroke in image coordinates, radius in image pixels.
class _EraseStroke {
  final List<Offset> points;
  final double radius;

  _EraseStroke(this.points, this.radius);
}

class _CutoutReviewScreenState extends State<CutoutReviewScreen> {
  /// The live cutout raster (base image with all strokes applied).
  ui.Image? _image;

  /// The untouched cutout the strokes are applied onto.
  ui.Image? _baseImage;

  /// Stroke history for undo (backend.md section 3.4: effectively "last 5").
  final List<_EraseStroke> _strokes = [];
  static const int maxUndoDepth = 5;

  /// Stroke currently being drawn, for live preview.
  _EraseStroke? _activeStroke;

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
          _baseImage = frame.image;
        });
      }
    } catch (e) {
      debugPrint('Could not load cutout for review: $e');
    }
  }

  // ---------------------------------------------------------------- eraser

  Offset _toImage(Offset local) => (local - _imageOrigin) / _scale;

  double _brushRadius() => 20.0 / _scale; // ~20px at display scale

  void _onPanStart(DragStartDetails d) {
    if (!_erasing || _image == null) return;
    setState(() {
      _activeStroke = _EraseStroke([_toImage(d.localPosition)], _brushRadius());
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_erasing || _activeStroke == null) return;
    setState(() => _activeStroke!.points.add(_toImage(d.localPosition)));
  }

  Future<void> _onPanEnd(DragEndDetails d) async {
    final stroke = _activeStroke;
    if (stroke == null || _image == null) return;
    setState(() {
      _strokes.add(stroke);
      // Cap the history at 5 strokes; undo steps back within that window
      // (backend.md section 3.4: "last 5").
      while (_strokes.length > maxUndoDepth) {
        _strokes.removeAt(0);
      }
      _activeStroke = null;
    });
    await _rerender();
  }

  /// Composites the base cutout with all strokes (dstOut soft stamps) into a
  /// fresh raster. No re-running the model (backend.md section 3.4).
  Future<void> _rerender() async {
    if (_baseImage == null) return;
    final base = _baseImage!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(base, Offset.zero, Paint());

    final erase = Paint()
      ..blendMode = BlendMode.dstOut
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void paintStroke(_EraseStroke s) {
      if (s.points.length == 1) {
        erase.maskFilter = MaskFilter.blur(BlurStyle.normal, s.radius * 0.35);
        canvas.drawCircle(s.points.first, s.radius, erase);
        return;
      }
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (final p in s.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      erase.strokeWidth = s.radius * 2;
      erase.maskFilter = MaskFilter.blur(BlurStyle.normal, s.radius * 0.35);
      canvas.drawPath(path, erase);
    }

    for (final s in _strokes) {
      paintStroke(s);
    }
    final rendered = await recorder.endRecording().toImage(
      base.width,
      base.height,
    );
    if (mounted) {
      setState(() => _image = rendered);
    }
  }

  Future<void> _undo() async {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
    await _rerender();
  }

  // --------------------------------------------------------------- actions

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      String? cutoutPath = widget.draftCutoutPath;
      if (_hasCutout && _image != null && _strokes.isNotEmpty) {
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
                    // Undo while strokes exist (last 5).
                    Tooltip(
                      message: 'Undo',
                      child: GestureDetector(
                        onTap: _strokes.isEmpty ? null : _undo,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _strokes.isEmpty
                                  ? c.hairline
                                  : c.inkSecondary,
                            ),
                          ),
                          child: Icon(
                            AppIcons.undo,
                            size: 20,
                            color: _strokes.isEmpty ? c.hairline : c.ink,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : _continue,
                        child: Text('Continue', style: AppText.button(context)),
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

/// Paints the cutout and the in-progress eraser stroke. Strokes erase alpha
/// (dstOut) with a soft round stamp (blur softening, backend.md section 3.4).
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
      ..strokeJoin = StrokeJoin.round;

    final stroke = activeStroke;
    if (stroke != null) {
      erase.strokeWidth = stroke.radius * 2;
      erase.maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        stroke.radius * 0.35,
      );
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

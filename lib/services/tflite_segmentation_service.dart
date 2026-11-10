// Real on-device segmentation replacing the stub
// (docs/backend.md section 3.2). Model: assets/models/u2netp_320.tflite,
// input [1,320,320,3] float32 NHWC, 7 outputs each [1,320,320,1] float32,
// output 0 is the final fused saliency map. Preprocessing follows the
// official U2-Net recipe (resize to 320x320 RGB, divide by the image max).
//
// On any failure (asset load, decode, inference, degenerate mask) this
// returns null so the documented fallback keeps the original photo
// (backend.md section 3.3); it never throws through the interface.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as im;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'mask_postprocessing.dart';
import 'segmentation_service.dart';

/// Bundled U2-Netp model (2.4 MB float16 conversion).
const String defaultSegmentationModelAsset =
    'assets/models/u2netp_320.tflite';

/// [SegmentationService] backed by the bundled U2-Netp TFLite model.
///
/// All heavy work (decode, preprocess, inference, compositing) runs inside a
/// background isolate via [Isolate.run]. The interpreter is created inside
/// that isolate per run: tflite_flutter 0.12.1's IsolateInterpreter only
/// offloads `runInference` while its setup and output copy are awkward, and
/// a native interpreter pointer cannot be created on one isolate and used on
/// another. Interpreter creation from the in-memory buffer is cheap next to
/// the U2-Netp forward pass; if profiling says otherwise, a long-lived
/// isolate owning the interpreter is the next step.
class TFLiteSegmentationService implements SegmentationService {
  TFLiteSegmentationService({this.modelAsset = defaultSegmentationModelAsset});

  final String modelAsset;

  /// Model bytes loaded once from assets and reused across runs.
  Uint8List? _modelBytes;

  Future<Uint8List?> _loadModel() async {
    final cached = _modelBytes;
    if (cached != null) return cached;
    final data = await rootBundle.load(modelAsset);
    return _modelBytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  @override
  Future<SegmentationResult?> segment(Uint8List imageBytes) async {
    try {
      final model = await _loadModel();
      if (model == null) return null;
      final job = _SegmentationJob(modelBytes: model, imageBytes: imageBytes);
      final png = await Isolate.run(() => _process(job));
      if (png == null) return null;
      return SegmentationResult(png);
    } catch (e, st) {
      debugPrint('Segmentation failed, keeping the original: $e\n$st');
      return null;
    }
  }
}

/// Everything the isolate needs; plain sendable fields only.
class _SegmentationJob {
  const _SegmentationJob({required this.modelBytes, required this.imageBytes});

  final Uint8List modelBytes;
  final Uint8List imageBytes;
}

/// Runs wholly inside a background isolate. Returns the RGBA cutout PNG, or
/// null on any failure.
Uint8List? _process(_SegmentationJob job) {
  final source = im.decodeImage(job.imageBytes);
  if (source == null) return null;

  final saliency = _runInference(job.modelBytes, source);
  final cutout = compositeCutout(saliency: saliency, source: source);
  if (cutout == null) return null;
  return im.encodePng(cutout);
}

/// Preprocesses [source] (320x320 RGB, max-normalized), runs the model, and
/// returns the fused d0 saliency map as [modelInputSize] x [modelInputSize]
/// floats in 0..1. Throws if the model or inference fails.
Float32List _runInference(Uint8List modelBytes, im.Image source) {
  final resized = im.copyResize(
    source,
    width: modelInputSize,
    height: modelInputSize,
    interpolation: im.Interpolation.linear,
  );

  // Official U2-Net recipe: divide pixels by the image's max value. If the
  // image is uniformly black (max 0) the input is all zeros and the empty
  // mask check downstream rejects the result.
  double maxValue = 0;
  for (final p in resized) {
    if (p.r.toDouble() > maxValue) maxValue = p.r.toDouble();
    if (p.g.toDouble() > maxValue) maxValue = p.g.toDouble();
    if (p.b.toDouble() > maxValue) maxValue = p.b.toDouble();
  }

  final input = Float32List(modelInputSize * modelInputSize * 3);
  var i = 0;
  for (final p in resized) {
    input[i++] = p.r.toDouble() / maxValue;
    input[i++] = p.g.toDouble() / maxValue;
    input[i++] = p.b.toDouble() / maxValue;
  }
  // Little-endian float32 raw bytes: Android targets are little-endian, and
  // tflite_flutter copies Uint8List inputs verbatim into the tensor.
  final inputBytes = Uint8List.view(input.buffer);

  final interpreter = Interpreter.fromBuffer(modelBytes);
  final numPixels = modelInputSize * modelInputSize;
  final saliency = Float32List(numPixels);
  final outputBytes = Uint8List.view(saliency.buffer);
  try {
    interpreter.runInference([inputBytes]);
    // Output index 0 is the final fused d0 map (backend.md section 3.2);
    // the six deep-supervision side outputs are ignored.
    interpreter.getOutputTensors()[0].copyTo(outputBytes);
  } finally {
    interpreter.close();
  }
  return saliency;
}

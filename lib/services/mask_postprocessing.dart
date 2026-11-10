// Post-processing of the U2-Net saliency map into an RGBA cutout
// (docs/backend.md section 3.2). Pure Dart with no Flutter imports so the
// whole pipeline is unit-testable on the host; the TFLite interpreter stays
// in [tflite_segmentation_service.dart].
//
// Pipeline: threshold -> despeckle -> feather -> bilinear upscale ->
// alpha-composite over the original pixels.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;

/// Side of the (square) saliency map the model emits.
const int modelInputSize = 320;

/// Saliency values at or above this become foreground. Tunable.
const double maskThreshold = 0.5;

/// Connected components smaller than this fraction of the total foreground
/// are dropped as speckle. Tunable.
const double despeckleMinComponentFraction = 0.01;

/// Gaussian radius (in map pixels) used to soften the mask edge. Tunable.
const int featherRadius = 2;

/// A mask covering less than this fraction of the frame is treated as
/// "nearly empty" (backend.md section 3.3) and rejected.
const double emptyMaskFraction = 0.01;

/// A mask covering more than this fraction of the frame is treated as
/// "all-full" (backend.md section 3.3) and rejected.
const double fullMaskFraction = 0.99;

/// Turns raw saliency values into a 0/1 binary mask
/// ([modelInputSize] x [modelInputSize], row-major).
Uint8List binarize(Float32List saliency, {double threshold = maskThreshold}) {
  final mask = Uint8List(saliency.length);
  for (var i = 0; i < saliency.length; i++) {
    mask[i] = saliency[i] >= threshold ? 1 : 0;
  }
  return mask;
}

/// Drops connected components (4-connectivity) smaller than
/// [minComponentFraction] of the total foreground. When every component is
/// below the threshold, the largest one is kept instead so a fragmented but
/// real mask is not emptied here (the empty/full checks in [compositeCutout]
/// decide separately whether the result is usable).
Uint8List despeckle(
  Uint8List mask,
  int size, {
  double minComponentFraction = despeckleMinComponentFraction,
}) {
  final n = size * size;
  var foreground = 0;
  for (var i = 0; i < n; i++) {
    if (mask[i] == 1) foreground++;
  }
  if (foreground == 0) return mask;

  final minArea = foreground * minComponentFraction;
  final labels = Int32List(n); // component id + 1; 0 = unvisited
  final areas = <int>[];
  final queue = <int>[];

  for (var start = 0; start < n; start++) {
    if (mask[start] != 1 || labels[start] != 0) continue;
    final id = areas.length + 1;
    var area = 0;
    queue.add(start);
    labels[start] = id;
    while (queue.isNotEmpty) {
      final i = queue.removeLast();
      area++;
      final x = i % size;
      final y = i ~/ size;
      if (x > 0 && mask[i - 1] == 1 && labels[i - 1] == 0) {
        labels[i - 1] = id;
        queue.add(i - 1);
      }
      if (x < size - 1 && mask[i + 1] == 1 && labels[i + 1] == 0) {
        labels[i + 1] = id;
        queue.add(i + 1);
      }
      if (y > 0 && mask[i - size] == 1 && labels[i - size] == 0) {
        labels[i - size] = id;
        queue.add(i - size);
      }
      if (y < size - 1 && mask[i + size] == 1 && labels[i + size] == 0) {
        labels[i + size] = id;
        queue.add(i + size);
      }
    }
    areas.add(area);
  }

  var keptAny = false;
  for (var c = 0; c < areas.length; c++) {
    if (areas[c] >= minArea) {
      keptAny = true;
      break;
    }
  }
  final kept = List<bool>.filled(areas.length, false);
  if (keptAny) {
    for (var c = 0; c < areas.length; c++) {
      kept[c] = areas[c] >= minArea;
    }
  } else {
    kept[_largestComponent(areas)] = true;
  }

  final cleaned = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (mask[i] == 1 && kept[labels[i] - 1]) cleaned[i] = 1;
  }
  return cleaned;
}

int _largestComponent(List<int> areas) {
  var best = 0;
  for (var c = 1; c < areas.length; c++) {
    if (areas[c] > areas[best]) best = c;
  }
  return best;
}

/// Gaussian-blurs the binary mask edge so the cutout gets a soft border.
/// Interior stays fully opaque, exterior fully transparent; only pixels
/// within [radius] of an edge land in between. Returns alpha 0..255.
Uint8List feather(Uint8List mask, int size, {int radius = featherRadius}) {
  final src = Float32List(size * size);
  for (var i = 0; i < src.length; i++) {
    src[i] = mask[i].toDouble();
  }
  final blurred = _blurSeparable(src, size, radius, sigma: radius * 0.5);
  final alpha = Uint8List(size * size);
  for (var i = 0; i < alpha.length; i++) {
    alpha[i] = (blurred[i].clamp(0.0, 1.0) * 255).round();
  }
  return alpha;
}

/// One-dimensional Gaussian kernel, edge-clamped convolution, two passes
/// (horizontal then vertical).
Float32List _blurSeparable(
  Float32List src,
  int size,
  int radius, {
  required double sigma,
}) {
  final kLen = 2 * radius + 1;
  final kernel = Float32List(kLen);
  var sum = 0.0;
  for (var i = 0; i < kLen; i++) {
    final d = (i - radius).toDouble();
    kernel[i] = math.exp(-(d * d) / (2 * sigma * sigma));
    sum += kernel[i];
  }
  for (var i = 0; i < kLen; i++) {
    kernel[i] /= sum;
  }

  final tmp = Float32List(src.length);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var acc = 0.0;
      for (var k = 0; k < kLen; k++) {
        final sx = (x + k - radius).clamp(0, size - 1);
        acc += src[y * size + sx] * kernel[k];
      }
      tmp[y * size + x] = acc;
    }
  }
  final out = Float32List(src.length);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var acc = 0.0;
      for (var k = 0; k < kLen; k++) {
        final sy = (y + k - radius).clamp(0, size - 1);
        acc += tmp[sy * size + x] * kernel[k];
      }
      out[y * size + x] = acc;
    }
  }
  return out;
}

/// Samples [map] (row-major, [size] x [size], values 0..1) at fractional
/// coordinates with bilinear interpolation, clamping outside the map.
double _bilinearSample(Float32List map, int size, double x, double y) {
  final cx = x.clamp(0.0, (size - 1).toDouble());
  final cy = y.clamp(0.0, (size - 1).toDouble());
  final x0 = cx.floor();
  final y0 = cy.floor();
  final x1 = (x0 + 1).clamp(0, size - 1);
  final y1 = (y0 + 1).clamp(0, size - 1);
  final fx = cx - x0;
  final fy = cy - y0;
  final v00 = map[y0 * size + x0];
  final v10 = map[y0 * size + x1];
  final v01 = map[y1 * size + x0];
  final v11 = map[y1 * size + x1];
  return (v00 * (1 - fx) + v10 * fx) * (1 - fy) +
      (v01 * (1 - fx) + v11 * fx) * fy;
}

/// Runs the full mask-to-cutout pipeline: threshold, despeckle, feather,
/// bilinear upscale to the source size, alpha composite.
///
/// Returns an RGBA [im.Image], or null when the mask is nearly empty or
/// all-full (backend.md section 3.3) so callers fall back to the original.
im.Image? compositeCutout({
  required Float32List saliency,
  required im.Image source,
}) {
  final binary = binarize(saliency);
  final cleaned = despeckle(binary, modelInputSize);

  var foreground = 0;
  final n = modelInputSize * modelInputSize;
  for (var i = 0; i < n; i++) {
    if (cleaned[i] == 1) foreground++;
  }
  if (foreground < n * emptyMaskFraction || foreground > n * fullMaskFraction) {
    return null;
  }

  final alpha = feather(cleaned, modelInputSize);
  final map = Float32List(n);
  for (var i = 0; i < n; i++) {
    map[i] = alpha[i] / 255.0;
  }

  final w = source.width;
  final h = source.height;
  final out = im.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    final sy = (y + 0.5) * modelInputSize / h - 0.5;
    for (var x = 0; x < w; x++) {
      final sx = (x + 0.5) * modelInputSize / w - 0.5;
      final a = (_bilinearSample(map, modelInputSize, sx, sy) * 255)
          .round()
          .clamp(0, 255);
      final p = source.getPixel(x, y);
      out.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), a);
    }
  }
  return out;
}

// Unit tests for the pure-Dart segmentation post-processing pipeline
// (docs/backend.md section 3.2). The TFLite interpreter itself cannot run on
// the host; see tflite_segmentation_service_test.dart for the fallback
// contract only.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:my_closet/services/mask_postprocessing.dart';

/// A [modelInputSize] x [modelInputSize] saliency map filled by [fill].
Float32List map(double Function(int x, int y) fill) {
  final m = Float32List(modelInputSize * modelInputSize);
  for (var y = 0; y < modelInputSize; y++) {
    for (var x = 0; x < modelInputSize; x++) {
      m[y * modelInputSize + x] = fill(x, y);
    }
  }
  return m;
}

Float32List rectangleMap({
  int left = 100,
  int top = 100,
  int right = 220,
  int bottom = 220,
  double inside = 1.0,
  double outside = 0.0,
}) {
  return map((x, y) {
    final inRect = x >= left && x <= right && y >= top && y <= bottom;
    return inRect ? inside : outside;
  });
}

im.Image solidImage(int w, int h, {int r = 200, int g = 30, int b = 40}) {
  final img = im.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixelRgb(x, y, r, g, b);
    }
  }
  return img;
}

void main() {
  group('binarize', () {
    test('perfect rectangle map becomes a clean mask', () {
      final binary = binarize(rectangleMap());
      var insideCount = 0;
      for (var i = 0; i < binary.length; i++) {
        if (binary[i] == 1) insideCount++;
      }
      // 121 x 121 pixels, inclusive bounds.
      expect(insideCount, 121 * 121);
      expect(binary[10 * modelInputSize + 10], 0);
      expect(binary[160 * modelInputSize + 160], 1);
    });

    test('threshold is inclusive at the boundary value', () {
      final binary = binarize(map((x, y) => x < 160 ? maskThreshold : 0.0));
      expect(binary[0], 1);
      expect(binary[160], 0);
    });
  });

  group('despeckle', () {
    test('drops components far below 1% of the foreground', () {
      final mask = binarize(rectangleMap());
      // Add a 3x3 speck far from the rectangle.
      for (var y = 20; y < 23; y++) {
        for (var x = 20; x < 23; x++) {
          mask[y * modelInputSize + x] = 1;
        }
      }
      final cleaned = despeckle(mask, modelInputSize);
      expect(cleaned[21 * modelInputSize + 21], 0, reason: 'speck removed');
      expect(cleaned[160 * modelInputSize + 160], 1, reason: 'body kept');
    });

    test('drops a single-pixel island below 1% of the foreground', () {
      final mask = Uint8List(modelInputSize * modelInputSize);
      // One 200 px island on one row, plus one stray pixel.
      for (var i = 0; i < 200; i++) {
        mask[1000 + i] = 1;
      }
      mask[50000] = 1;
      final cleaned = despeckle(mask, modelInputSize);
      expect(cleaned[1000], 1);
      expect(cleaned[50000], 0);
    });

    test('when every component is below the threshold, the largest is kept',
        () {
      final mask = Uint8List(modelInputSize * modelInputSize);
      // Two islands of 60 px and 40 px; with a threshold of 80 px (80% of
      // the 100 px foreground) neither qualifies.
      for (var i = 0; i < 60; i++) {
        mask[1000 + i] = 1;
      }
      for (var i = 0; i < 40; i++) {
        mask[50000 + i] = 1;
      }
      final cleaned = despeckle(
        mask,
        modelInputSize,
        minComponentFraction: 0.8,
      );
      expect(cleaned[1000], 1, reason: 'largest island kept');
      expect(cleaned[50000], 0, reason: 'smaller island dropped');
    });

    test('empty mask stays empty', () {
      final cleaned =
          despeckle(Uint8List(modelInputSize * modelInputSize), modelInputSize);
      expect(cleaned.every((v) => v == 0), isTrue);
    });
  });

  group('feather', () {
    test('interior opaque, exterior transparent, edge in between', () {
      final alpha = feather(binarize(rectangleMap()), modelInputSize);
      expect(alpha[160 * modelInputSize + 160], 255, reason: 'interior');
      expect(alpha[10 * modelInputSize + 10], 0, reason: 'exterior');
      // The rectangle edge itself must be partially opaque (feathered).
      final edgeAlpha = alpha[100 * modelInputSize + 160];
      expect(edgeAlpha, greaterThan(0));
      expect(edgeAlpha, lessThan(255));
    });
  });

  group('compositeCutout', () {
    test('full pipeline on a rectangle map yields the cutout', () {
      final cutout = compositeCutout(
          saliency: rectangleMap(), source: solidImage(640, 640));
      expect(cutout, isNotNull);
      expect(cutout!.width, 640);
      expect(cutout.height, 640);
      // Center opaque and keeps the source color; corner fully transparent.
      expect(cutout.getPixel(320, 320).a, 255);
      expect(cutout.getPixel(320, 320).r, 200);
      expect(cutout.getPixel(5, 5).a, 0);
      // Encodes to a valid PNG.
      final png = im.encodePng(cutout);
      expect(png.length, greaterThan(0));
    });

    test('gradient edge produces feathered alpha strictly between 0 and 255',
        () {
      // Rectangle with a soft ramp on the left edge so the gaussian feather
      // and the bilinear upscale both land in the intermediate range.
      const left = 100;
      const rampWidth = 12;
      final saliency = map((x, y) {
        if (x < left - rampWidth) return 0.0;
        if (x < left) return (x - (left - rampWidth)) / rampWidth;
        return (x <= 220 && y >= 100 && y <= 220) ? 1.0 : 0.0;
      });
      final cutout =
          compositeCutout(saliency: saliency, source: solidImage(320, 320));
      expect(cutout, isNotNull);
      // Middle of the transition band: partially opaque.
      final midAlpha = cutout!.getPixel(95, 160).a;
      expect(midAlpha, greaterThan(0));
      expect(midAlpha, lessThan(255));
      expect(cutout.getPixel(160, 160).a, 255);
      expect(cutout.getPixel(20, 160).a, 0);
    });

    test('nearly empty saliency returns null', () {
      final saliency =
          map((x, y) => (x < 5 && y < 5) ? 1.0 : 0.0);
      expect(compositeCutout(saliency: saliency, source: solidImage(320, 320)),
          isNull);
    });

    test('all-full saliency returns null', () {
      final saliency = map((x, y) => 1.0);
      expect(compositeCutout(saliency: saliency, source: solidImage(320, 320)),
          isNull);
    });
  });
}

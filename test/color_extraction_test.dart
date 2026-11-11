import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:my_closet/services/color_extraction_service.dart';

/// Synthetic-image tests for color extraction (docs/backend.md section 4).
img.Image _flat(int width, int height, int r, int g, int b, [int a = 255]) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, r, g, b, a);
    }
  }
  return image;
}

/// Horizontal band image: [cols] columns of color A, rest color B.
img.Image _twoBands(
  int width,
  int height,
  List<int> a,
  List<int> b,
  int cols,
) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = x < cols ? a : b;
      image.setPixelRgba(x, y, c[0], c[1], c[2], c.length > 3 ? c[3] : 255);
    }
  }
  return image;
}

/// Three horizontal bands: top band [a] for [rowsA] rows, middle band [b]
/// for [rowsB] rows, rest band [c].
img.Image _threeBands(
  int width,
  int height,
  List<int> a,
  List<int> b,
  List<int> c,
  int rowsA,
  int rowsB,
) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final color = y < rowsA ? a : (y < rowsA + rowsB ? b : c);
      image.setPixelRgba(x, y, color[0], color[1], color[2], 255);
    }
  }
  return image;
}

void main() {
  const service = ColorExtractionService();

  group('primary color', () {
    test('flat opaque image yields the exact color', () {
      final result = service.extract(_flat(60, 60, 255, 0, 0));
      expect(result.primaryHex, '#FF0000');
      expect(result.primaryName, isNotNull);
    });

    test('largest region wins when two colors are present', () {
      final result = service.extract(
        _twoBands(60, 60, [255, 0, 0], [0, 0, 255], 40),
      );
      expect(result.primaryHex, '#FF0000');
    });

    test('fully transparent cutout yields no colors', () {
      final result = service.extract(_flat(40, 40, 255, 105, 180, 0));
      expect(result.primaryHex, isNull);
      expect(result.secondaryHex, isNull);
    });
  });

  group('secondary color', () {
    test('distinct second region becomes the secondary color', () {
      final result = service.extract(
        _twoBands(60, 60, [255, 0, 0], [0, 0, 255], 40),
      );
      expect(result.secondaryHex, '#0000FF');
    });

    test('near-identical colors merge into one plain item (Delta E < 40)', () {
      // #FF0000 and #F01010 are lighting variants of one red: after the
      // merge step they are a single cluster, so the item stays plain and
      // the primary is the count-weighted centroid of both bands.
      final result = service.extract(
        _twoBands(60, 60, [255, 0, 0], [240, 16, 16], 40),
      );
      expect(result.secondaryHex, isNull);
      // (255*40 + 240*20) / 60 = 250, same for the weighted G/B channels.
      expect(result.primaryHex, '#FA0505');
    });

    test('highlight/shadow fragments merge into the dominant shade', () {
      // A "shadow" band only 5 RGB steps darker must not survive as a
      // second cluster - it folds into the main color.
      final report = service.extractWithDiagnostics(
        _twoBands(60, 60, [30, 60, 120], [25, 55, 115], 45),
      );
      expect(report.clusters, hasLength(1));
      expect(report.extracted.secondaryHex, isNull);
    });

    test('transparent background pixels are ignored', () {
      // Pink background at alpha 0 in the top half, opaque green garment in
      // the bottom half.
      final image = img.Image(width: 60, height: 60, numChannels: 4);
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 60; x++) {
          if (y < 30) {
            image.setPixelRgba(x, y, 255, 105, 180, 0);
          } else {
            image.setPixelRgba(x, y, 0, 200, 60, 255);
          }
        }
      }
      final result = service.extract(image);
      expect(result.primaryHex, '#00C83C');
      expect(result.secondaryHex, isNull);
    });
  });

  group('multi-color garments', () {
    test('light second color in the Delta E 25-40 band is reported', () {
      // White (20% share) on sky blue sits at Delta E ~32 - a real second
      // color (stripes) that the old flat Delta E 40 cutoff dropped, leaving
      // the secondary empty.
      final result = service.extract(
        _twoBands(60, 60, [143, 193, 227], [250, 250, 250], 40),
      );
      expect(result.primaryHex, '#8FC1E3');
      expect(result.secondaryHex, '#FAFAFA');
    });

    test('kept background halo does not become a phantom secondary', () {
      // Segmentation sometimes keeps a 1-2 px opaque ring of background
      // around the garment. The ring is erosion-dropped, so it must not
      // surface as the item's second color (it used to: a grey halo at 12%
      // share passed the old Delta E check and became the secondary).
      final image = img.Image(width: 100, height: 100, numChannels: 4);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          if (x >= 20 && x < 80 && y >= 20 && y < 80) {
            image.setPixelRgba(x, y, 0, 200, 60, 255); // garment
          } else if (x >= 18 && x < 82 && y >= 18 && y < 82) {
            image.setPixelRgba(x, y, 200, 200, 200, 255); // kept halo
          } else {
            image.setPixelRgba(x, y, 255, 105, 180, 0); // background
          }
        }
      }
      final report = service.extractWithDiagnostics(image);
      expect(report.extracted.primaryHex, '#00C83C');
      expect(report.extracted.secondaryHex, isNull);
    });

    test('same-hue shade band stays out of the secondary slot', () {
      // A darker band of the same red at Delta E ~29 - inside the new 25-40
      // acceptance band. It is lighting, not a second color: same hue, both
      // chromatic, so the distinctness check must reject it.
      final result = service.extract(
        _twoBands(60, 60, [220, 70, 70], [130, 30, 30], 45),
      );
      expect(result.secondaryHex, isNull);
    });

    test('tiny noise cluster under the share floor is not a secondary', () {
      // A 3%-share tan sliver next to a navy body is Delta E ~70 away -
      // the old pipeline happily reported it as the secondary color - but
      // too small to be a real second garment color.
      final image = img.Image(width: 100, height: 100, numChannels: 4);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          if (x < 97) {
            image.setPixelRgba(x, y, 28, 43, 74, 255); // navy body
          } else {
            image.setPixelRgba(x, y, 180, 140, 90, 255); // tan sliver
          }
        }
      }
      final result = service.extract(image);
      expect(result.primaryHex, '#1C2B4A');
      expect(result.secondaryHex, isNull);
    });

    test('distinct three-color garment reports its two dominant colors', () {
      // Red body (50%), thin white middle band (13%), blue bottom band (37%):
      // k = 5 must keep all three centroids alive and report the two largest
      // distinct colors (red, then blue - not the thinner white band).
      final image = _threeBands(
        60,
        60,
        [220, 20, 20],
        [250, 250, 250],
        [0, 0, 220],
        30,
        8,
      );
      final result = service.extract(image);
      expect(result.primaryHex, '#DC1414');
      expect(result.secondaryHex, '#0000DC');
    });
  });

  group('named-color snapping', () {
    test('exact curated hex snaps to its name', () {
      final result = service.extract(_flat(40, 40, 28, 43, 74)); // #1C2B4A
      expect(result.primaryHex, '#1C2B4A');
      expect(result.primaryName, 'navy');
    });

    test('off-palette hex snaps to the nearest curated name', () {
      // #10182A is a very dark navy - nearer navy than any other entry.
      final result = service.extract(_flat(40, 40, 16, 24, 42));
      expect(result.primaryName, 'navy');
    });
  });

  group('determinism', () {
    test('same input, same output', () {
      final image = _twoBands(120, 120, [255, 0, 0], [0, 200, 60], 50);
      final a = service.extract(image);
      final b = service.extract(image);
      expect(a.primaryHex, b.primaryHex);
      expect(a.secondaryHex, b.secondaryHex);
      expect(a.primaryName, b.primaryName);
    });
  });
}

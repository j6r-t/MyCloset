import 'dart:math' as math;

/// Pure color-space math shared by the color extraction service and the
/// suggestion engine. All conversions are deterministic.
///
/// Conventions:
/// - Hex strings are '#RRGGBB', uppercase, e.g. '#1C2B4A'.
/// - HSV/HSL saturation and value/lightness are 0..1; hue is 0..360 degrees.
/// - CIELAB uses the D65 reference white; color distance is Delta E 76
///   (euclidean distance in Lab space), per docs/backend.md sections 4-5.

class HsvColor {
  /// Hue in degrees, 0..360. Undefined (0) for pure grays.
  final double h;

  /// Saturation, 0..1.
  final double s;

  /// Value (brightness), 0..1.
  final double v;

  const HsvColor(this.h, this.s, this.v);

  @override
  String toString() => 'Hsv(${h.round()}deg, ${s.toStringAsFixed(2)}, ${v.toStringAsFixed(2)})';
}

class LabColor {
  final double l;
  final double a;
  final double b;

  const LabColor(this.l, this.a, this.b);
}

/// RGB (0..255 channels) to HSV.
HsvColor rgbToHsv(int r, int g, int b) {
  final rf = r / 255.0;
  final gf = g / 255.0;
  final bf = b / 255.0;
  final max = math.max(rf, math.max(gf, bf));
  final min = math.min(rf, math.min(gf, bf));
  final d = max - min;

  var h = 0.0;
  if (d > 0) {
    if (max == rf) {
      h = 60.0 * (((gf - bf) / d) % 6.0);
    } else if (max == gf) {
      h = 60.0 * (((bf - rf) / d) + 2.0);
    } else {
      h = 60.0 * (((rf - gf) / d) + 4.0);
    }
    if (h < 0) h += 360.0;
  }
  final s = max == 0 ? 0.0 : d / max;
  return HsvColor(h, s, max);
}

/// Circular hue distance in degrees, 0..180.
double hueDistance(double a, double b) {
  final d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

double _srgbChannelToLinear(double c) {
  final v = c / 255.0;
  return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

double _labF(double t) {
  const epsilon = 216.0 / 24389.0;
  const kappa = 24389.0 / 27.0;
  return t > epsilon ? _cbrt(t) : (kappa * t + 16.0) / 116.0;
}

double _cbrt(double x) => x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

/// RGB (0..255, sRGB) to CIELAB with the D65 reference white.
LabColor rgbToLab(int r, int g, int b) {
  final rl = _srgbChannelToLinear(r.toDouble());
  final gl = _srgbChannelToLinear(g.toDouble());
  final bl = _srgbChannelToLinear(b.toDouble());

  final x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047;
  final y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl;
  final z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883;

  final fx = _labF(x);
  final fy = _labF(y);
  final fz = _labF(z);

  return LabColor(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz));
}

/// Euclidean distance in CIELAB (Delta E 76).
double labDistance(LabColor a, LabColor b) {
  final dl = a.l - b.l;
  final da = a.a - b.a;
  final db = a.b - b.b;
  return math.sqrt(dl * dl + da * da + db * db);
}

/// Euclidean distance in RGB space, used by k-means.
double rgbDistance(List<int> p, List<int> q) {
  final dr = p[0] - q[0].toDouble();
  final dg = p[1] - q[1].toDouble();
  final db = p[2] - q[2].toDouble();
  return math.sqrt(dr * dr + dg * dg + db * db);
}

/// Parses '#RRGGBB' (with or without '#', any case). Returns null if invalid.
List<int>? hexToRgb(String hex) {
  var s = hex.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null || v < 0 || v > 0xFFFFFF) return null;
  return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
}

/// Formats RGB channels as '#RRGGBB' (uppercase).
String rgbToHex(int r, int g, int b) {
  String two(int v) => v.clamp(0, 255).toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${two(r)}${two(g)}${two(b)}';
}

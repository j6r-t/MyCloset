import 'dart:math' as math;

import '../services/color_math.dart';

/// A curated fashion color name, per docs/backend.md section 4. The list is
/// deliberately closed so the suggestion engine works on a fixed vocabulary.
class NamedColor {
  final String name;
  final String hex;

  const NamedColor(this.name, this.hex);
}

/// 36 curated fashion color names. Display order follows the color wheel so a
/// UI can render the named-color picker as a grid.
const List<NamedColor> kNamedColors = [
  // Neutrals
  NamedColor('black', '#000000'),
  NamedColor('charcoal', '#36454F'),
  NamedColor('grey', '#8A8A8A'),
  NamedColor('silver', '#C6C6C6'),
  NamedColor('white', '#FAFAFA'),
  NamedColor('ivory', '#FFFFF0'),
  NamedColor('cream', '#F5EFDC'),
  NamedColor('beige', '#E8DCC8'),
  NamedColor('camel', '#C19A6B'),
  NamedColor('tan', '#D2B48C'),
  NamedColor('khaki', '#C3B091'),
  NamedColor('chocolate', '#5B3A29'),
  // Reds and oranges
  NamedColor('burgundy', '#800020'),
  NamedColor('wine', '#722F37'),
  NamedColor('scarlet', '#FF2400'),
  NamedColor('coral', '#FF7F50'),
  NamedColor('rust', '#B7410E'),
  NamedColor('terracotta', '#E2725B'),
  NamedColor('burnt orange', '#CC5500'),
  NamedColor('mustard', '#E1AD01'),
  NamedColor('gold', '#D4AF37'),
  // Pinks and purples
  NamedColor('blush', '#F2A6B3'),
  NamedColor('rose', '#E0607E'),
  NamedColor('fuchsia', '#D6479E'),
  NamedColor('plum', '#8E4585'),
  NamedColor('lavender', '#B9A7D6'),
  NamedColor('purple', '#7B4B94'),
  // Blues
  NamedColor('navy', '#1C2B4A'),
  NamedColor('denim blue', '#3B6EA5'),
  NamedColor('royal blue', '#4169E1'),
  NamedColor('sky blue', '#8FC1E3'),
  NamedColor('teal', '#008080'),
  NamedColor('turquoise', '#40E0D0'),
  // Greens
  NamedColor('sage', '#9CAF88'),
  NamedColor('olive', '#808000'),
  NamedColor('forest green', '#228B22'),
];

/// HSV saturation below which a color counts as (near) neutral for naming:
/// an extracted centroid with less chroma than this is snapped among the
/// neutral names only, so a black garment photographed warm never lands on
/// 'chocolate' and an off-white knit never lands on 'blush'.
const double neutralSaturationMax = 0.12;

/// The neutral names a near-achromatic centroid may snap to. Lightness is
/// what separates them, which is why the snap distance is unweighted for
/// this set.
const Set<String> _neutralNames = {
  'black',
  'charcoal',
  'grey',
  'silver',
  'white',
  'ivory',
  'cream',
  'beige',
};

/// How much more the naming distance cares about chroma (a/b in Lab) than
/// lightness for chromatic colors: misnaming hue ('navy' -> 'forest green')
/// reads as wrong far more often than a lightness step ('navy' -> 'royal
/// blue'), so hue errors must cost more.
const double _chromaWeight = 1.5;

/// Finds the nearest curated color by CIELAB distance. Returns null when
/// [hex] is not a valid '#RRGGBB' string.
///
/// Naming rules (beyond raw distance):
/// - A near-neutral centroid (HSV saturation <= [neutralSaturationMax])
///   snaps among the neutral names only. Raw nearest-color would send a
///   slightly warm black to 'chocolate' or a slightly cool white to 'sky
///   blue' - real extraction centroids are never perfectly achromatic.
/// - For chromatic colors the a/b (chroma) axes are weighted
///   [_chromaWeight]x against lightness, since hue mismatches are the
///   noticeable ones.
NamedColor? snapToNamedColor(String hex) {
  final rgb = hexToRgb(hex);
  if (rgb == null) return null;
  final lab = rgbToLab(rgb[0], rgb[1], rgb[2]);
  final neutral = rgbToHsv(rgb[0], rgb[1], rgb[2]).s <= neutralSaturationMax;

  NamedColor? best;
  var bestDistance = double.infinity;
  for (final named in kNamedColors) {
    if (neutral && !_neutralNames.contains(named.name)) continue;
    final candidateRgb = hexToRgb(named.hex)!;
    final candidateLab = rgbToLab(candidateRgb[0], candidateRgb[1], candidateRgb[2]);
    final dl = lab.l - candidateLab.l;
    final da = (lab.a - candidateLab.a) * (neutral ? 1.0 : _chromaWeight);
    final db = (lab.b - candidateLab.b) * (neutral ? 1.0 : _chromaWeight);
    final d = math.sqrt(dl * dl + da * da + db * db);
    if (d < bestDistance) {
      bestDistance = d;
      best = named;
    }
  }
  return best;
}

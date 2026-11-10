import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../data/named_colors.dart';
import '../models/enums.dart';
import '../models/item.dart';
import 'color_math.dart';

/// One transcribed Wada palette group (docs/backend.md section 5.3): a named
/// set of hex colors that historically pair well.
class PaletteGroup {
  final String name;
  final List<String> hexes;

  const PaletteGroup(this.name, this.hexes);
}

/// Loads the transcribed book palettes from `assets/data/palettes.json`.
///
/// Expected format:
/// ```json
/// { "palettes": [ { "name": "wada-001", "colors": ["#1C2B4A", "#E1AD01"] } ] }
/// ```
///
/// Transcription of the book is a later data task; until then the file holds
/// an empty palettes array and this returns an empty list. Any load or parse
/// failure also degrades to an empty list - the palette bonus is optional.
Future<List<PaletteGroup>> loadPalettes([
  String assetPath = 'assets/data/palettes.json',
]) async {
  try {
    final raw = await rootBundle.loadString(assetPath);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return const [];
    final list = decoded['palettes'];
    if (list is! List) return const [];
    final groups = <PaletteGroup>[];
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['name'];
      final colors = entry['colors'];
      if (name is String && colors is List) {
        final hexes = colors.whereType<String>().toList();
        if (hexes.isNotEmpty) {
          groups.add(PaletteGroup(name, hexes));
        }
      }
    }
    return groups;
  } catch (_) {
    return const [];
  }
}

/// The rule that won a color pair, plus its phrase for the reason line.
class PairScore {
  final int score;
  final String rule;
  final String reasonPhrase;

  const PairScore(this.score, this.rule, this.reasonPhrase);
}

/// Full scoring result for one candidate outfit.
class ScoreBreakdown {
  /// Sum of the pairwise harmony scores (backend.md 5.2 table).
  final double pairTotal;

  /// Penalties (loud primaries, 3+ chromatic colors, accessory mismatch),
  /// zero or negative.
  final double penalties;

  /// Book palette bonus, 0 or +5.
  final double paletteBonus;
  final double total;

  /// Best-scoring pair, for the one-line reason.
  final PairScore? bestPair;

  /// Names of the two colors in [bestPair].
  final String bestPairLabel;

  /// The one-liner shown on a suggestion card, e.g.
  /// "Navy + mustard - complementary accents".
  final String reason;

  const ScoreBreakdown({
    required this.pairTotal,
    required this.penalties,
    required this.paletteBonus,
    required this.total,
    required this.bestPair,
    required this.bestPairLabel,
    required this.reason,
  });
}

/// One complete suggested outfit.
class Suggestion {
  final Map<OutfitSlot, Item> slots;
  final ScoreBreakdown breakdown;

  const Suggestion(this.slots, this.breakdown);

  /// Stable identity of the combo (same slots, same items). Used for
  /// deduplication and for excluding previously shown combos while
  /// shuffling (backend.md 5.4).
  String get key {
    final parts = slots.entries
        .map((e) => '${e.key.name}:${e.value.id}')
        .toList()
      ..sort();
    return parts.join('|');
  }
}

/// Buckets for the live harmony readout in the outfit builder
/// (backend.md 5.5).
enum HarmonyBucket { harmonious, mixed, clashing }

/// Deterministic, rule-based outfit suggestion engine (docs/backend.md 5).
///
/// Runs entirely offline on the in-memory wardrobe; no randomness anywhere,
/// so the same wardrobe always produces the same ranking.
class SuggestionEngine {
  /// Thresholds and weights, kept as constants so the spreadsheet prototype
  /// (plan requirement) and this code stay in sync.
  static const double neutralMaxSaturation = 0.18;
  static const double loudSaturation = 0.55;
  static const double loudValue = 0.55;
  static const double loudPrimariesPenalty = -4.0;
  static const double extraChromaticPenalty = -3.0;
  static const double accessoryMismatchPenalty = -2.0;
  static const double paletteBonus = 5.0;
  static const double paletteMaxDeltaE = 25.0;

  /// Live readout buckets (backend.md 5.5).
  static const double harmoniousThreshold = 18.0;
  static const double mixedThreshold = 12.0;

  final List<PaletteGroup> palettes;

  const SuggestionEngine({this.palettes = const []});

  // ------------------------------------------------------------- public API

  /// Builds candidates over the whole wardrobe and returns the top [limit]
  /// suggestions.
  ///
  /// [exclude] removes previously shown combo keys while shuffling
  /// (backend.md 5.4).
  List<Suggestion> suggest(
    List<Item> wardrobe, {
    Set<String> exclude = const {},
    int limit = 3,
  }) {
    final bySlot = <OutfitSlot, List<Item>>{};
    for (final item in wardrobe) {
      final slot = _slotFor(item.category);
      bySlot.putIfAbsent(slot, () => []).add(item);
    }
    final dresses = bySlot[OutfitSlot.dress] ?? const <Item>[];
    final tops = bySlot[OutfitSlot.top] ?? const <Item>[];
    final bottoms = bySlot[OutfitSlot.bottom] ?? const <Item>[];
    final shoes = bySlot[OutfitSlot.shoes] ?? const <Item>[];
    final outerwears = bySlot[OutfitSlot.outerwear] ?? const <Item>[];
    final accessories = bySlot[OutfitSlot.accessory] ?? const <Item>[];

    final candidates = <String, Suggestion>{};

    // Tops whose layer_type lets them double as outerwear (schema v2 rule,
    // backend.md 5.1): layer_type outer or both. They stay eligible for the
    // top slot as well; see the pool assembly inside [consider].
    bool canLayerAsOuterwear(Item item) =>
        item.category == Category.outerwear ||
        (item.category == Category.top &&
            (item.layerType == LayerType.outer ||
                item.layerType == LayerType.both));
    final layeringTops = tops.where(canLayerAsOuterwear).toList();

    void consider(Map<OutfitSlot, Item> base) {
      final seasons = _specificSeasons(base.values);
      if (_violatesSeasonGate(seasons)) return;

      var current = base;
      var currentScore = scoreOutfit(current).total;

      // Outerwear: optional, only season-compatible items are eligible
      // (backend.md 5.1); the best-matching one wins. Adding is skipped
      // entirely when every candidate lowers the score. The pool includes
      // layering tops (layer_type outer/both) besides real outerwear, but a
      // top cannot also fill this candidate's own top slot - one garment is
      // never worn twice in one outfit.
      final baseTop = base[OutfitSlot.top];
      final outerwearSeasons = _specificSeasons(current.values);
      Item? bestOuterwear;
      var bestOuterwearScore = currentScore;
      for (final o in outerwears.followedBy(layeringTops)) {
        if (baseTop != null && o.id == baseTop.id) continue;
        final compatible = o.season == Season.all ||
            outerwearSeasons.isEmpty ||
            outerwearSeasons.contains(o.season);
        if (!compatible) continue;
        final candidate = Map<OutfitSlot, Item>.of(current)
          ..[OutfitSlot.outerwear] = o;
        final s = scoreOutfit(candidate).total;
        if (s > bestOuterwearScore) {
          bestOuterwearScore = s;
          bestOuterwear = o;
        }
      }
      if (bestOuterwear != null) {
        current = Map<OutfitSlot, Item>.of(current)
          ..[OutfitSlot.outerwear] = bestOuterwear;
        currentScore = bestOuterwearScore;
      }

      // Accessory: optional as well. Unlike outerwear, a season-conflicting
      // accessory is still eligible - it takes the -2 mismatch penalty
      // inside the scoring instead of being filtered out.
      Item? bestAccessory;
      var bestAccessoryScore = currentScore;
      for (final a in accessories) {
        final candidate = Map<OutfitSlot, Item>.of(current)
          ..[OutfitSlot.accessory] = a;
        final s = scoreOutfit(candidate).total;
        if (s > bestAccessoryScore) {
          bestAccessoryScore = s;
          bestAccessory = a;
        }
      }
      if (bestAccessory != null) {
        current = Map<OutfitSlot, Item>.of(current)
          ..[OutfitSlot.accessory] = bestAccessory;
      }

      final suggestion = Suggestion(current, scoreOutfit(current));
      candidates.putIfAbsent(suggestion.key, () => suggestion);
    }

    for (final dress in dresses) {
      for (final shoe in shoes) {
        consider({
          OutfitSlot.dress: dress,
          OutfitSlot.shoes: shoe,
        });
      }
    }
    for (final top in tops) {
      for (final bottom in bottoms) {
        for (final shoe in shoes) {
          consider({
            OutfitSlot.top: top,
            OutfitSlot.bottom: bottom,
            OutfitSlot.shoes: shoe,
          });
        }
      }
    }

    final ranked = candidates.values
        .where((s) => !exclude.contains(s.key))
        .toList()
      ..sort((a, b) {
        final byScore = b.breakdown.total.compareTo(a.breakdown.total);
        return byScore != 0 ? byScore : a.key.compareTo(b.key);
      });

    return ranked.take(limit).toList();
  }

  /// Scores an arbitrary partial outfit; used live by the outfit builder
  /// readout (backend.md 5.5).
  HarmonyBucket harmonyReadout(Map<OutfitSlot, Item> slots) {
    final total = scoreOutfit(slots).total;
    if (total >= harmoniousThreshold) return HarmonyBucket.harmonious;
    if (total >= mixedThreshold) return HarmonyBucket.mixed;
    return HarmonyBucket.clashing;
  }

  /// Full scoring of one candidate (backend.md 5.2 + 5.3).
  ScoreBreakdown scoreOutfit(Map<OutfitSlot, Item> slots) {
    final entries = slots.entries.toList()
      ..sort((a, b) => a.key.index.compareTo(b.key.index));

    final hsv = <_SlotColor>[];
    for (final entry in entries) {
      final parsed = hexToRgb(entry.value.colorPrimaryHex);
      hsv.add(
        parsed == null
            ? _SlotColor(entry.value, const HsvColor(0, 0, 0))
            : _SlotColor(
                entry.value,
                rgbToHsv(parsed[0], parsed[1], parsed[2]),
              ),
      );
    }

    // Pairwise harmony.
    var pairTotal = 0.0;
    PairScore? bestPair;
    var bestPairScore = -1;
    String bestPairLabel = '';
    for (var i = 0; i < hsv.length; i++) {
      for (var j = i + 1; j < hsv.length; j++) {
        final pair = scorePair(hsv[i].hsv, hsv[j].hsv);
        pairTotal += pair.score;
        if (pair.score > bestPairScore) {
          bestPairScore = pair.score;
          bestPair = pair;
          bestPairLabel = '${_colorName(hsv[i].item)} + ${_colorName(hsv[j].item)}';
        }
      }
    }

    // Penalties.
    var penalties = 0.0;

    var loudCount = 0;
    var chromaticCount = 0;
    for (final c in hsv) {
      if (c.hsv.s > loudSaturation && c.hsv.v > loudValue) loudCount++;
      if (c.hsv.s >= neutralMaxSaturation) chromaticCount++;
    }
    if (loudCount >= 2) penalties += loudPrimariesPenalty;
    if (chromaticCount >= 3) {
      penalties += extraChromaticPenalty * (chromaticCount - 2);
    }

    // Accessory season mismatch: an accessory whose season conflicts with
    // the outfit's specific season is allowed in but penalized (see the
    // comment on [accessoryMismatchPenalty]). The outfit's seasons are read
    // from the non-accessory slots so the accessory cannot mask its own
    // mismatch.
    final accessory = slots[OutfitSlot.accessory];
    if (accessory != null && accessory.season != Season.all) {
      final seasons = _specificSeasons(
        slots.entries
            .where((e) => e.key != OutfitSlot.accessory)
            .map((e) => e.value),
      );
      if (seasons.isNotEmpty && !seasons.contains(accessory.season)) {
        penalties += accessoryMismatchPenalty;
      }
    }

    // Book palette bonus (backend.md 5.3): +5 when two primaries both
    // appear (Delta E 25 tolerance) within one palette group.
    var bonus = 0.0;
    String paletteReason = '';
    for (final group in palettes) {
      for (var i = 0; i < hsv.length && bonus == 0; i++) {
        for (var j = i + 1; j < hsv.length && bonus == 0; j++) {
          if (_bothInPalette(hsv[i], hsv[j], group)) {
            bonus = paletteBonus;
            paletteReason =
                'Wada palette pairing (${_colorName(hsv[i].item)} + '
                '${_colorName(hsv[j].item)}, ${group.name})';
          }
        }
      }
      if (bonus > 0) break;
    }

    final total = pairTotal + penalties + bonus;

    final String reason;
    if (bonus > 0) {
      reason = paletteReason;
    } else if (bestPair != null) {
      reason = '$bestPairLabel - ${bestPair.reasonPhrase}';
    } else {
      reason = '';
    }

    return ScoreBreakdown(
      pairTotal: pairTotal,
      penalties: penalties,
      paletteBonus: bonus,
      total: total,
      bestPair: bestPair,
      bestPairLabel: bestPairLabel,
      reason: reason,
    );
  }

  /// Harmony scoring for one pair of primary colors (backend.md 5.2 table).
  ///
  /// Hue distance is circular (0..180), which folds the table's
  /// split-complementary ranges 100-150 and 210-260 onto a single 100-150
  /// band and makes the complementary band 150-180. When several rules
  /// match, the highest score wins; if none matches the pair scores 2
  /// (clash).
  ///
  /// Achromatic colors (saturation < 0.18) have no meaningful hue, so the
  /// hue-distance rules cannot match a pair that includes one; such pairs
  /// are covered by the neutral + accent rule instead.
  PairScore scorePair(HsvColor a, HsvColor b) {
    final d = hueDistance(a.h, b.h);
    final neutral = a.s < neutralMaxSaturation || b.s < neutralMaxSaturation;

    PairScore best = const PairScore(2, 'clash', 'bold clash');

    void consider(bool applies, int score, String rule, String phrase) {
      if (applies && score > best.score) {
        best = PairScore(score, rule, phrase);
      }
    }

    consider(d < 20 && !neutral, 6, 'monochrome', 'tone-on-tone');
    consider(!neutral && d >= 20 && d < 50, 7, 'analogous',
        'analogous neighbours');
    consider(!neutral && d >= 150, 9, 'complementary',
        'complementary accents');
    consider(!neutral && d >= 100 && d < 150, 7, 'split-complementary',
        'triadic balance');
    consider(neutral, 8, 'neutral-accent', 'quiet base, one accent');

    return best;
  }

  // -------------------------------------------------------------- internals

  _SlotColor? _matchingColor(_SlotColor c, PaletteGroup group) {
    final rgb = hexToRgb(c.item.colorPrimaryHex);
    if (rgb == null) return null;
    final lab = rgbToLab(rgb[0], rgb[1], rgb[2]);
    for (final hex in group.hexes) {
      final paletteRgb = hexToRgb(hex);
      if (paletteRgb == null) continue;
      final paletteLab = rgbToLab(paletteRgb[0], paletteRgb[1], paletteRgb[2]);
      if (labDistance(lab, paletteLab) <= paletteMaxDeltaE) {
        return c;
      }
    }
    return null;
  }

  bool _bothInPalette(_SlotColor a, _SlotColor b, PaletteGroup group) =>
      _matchingColor(a, group) != null && _matchingColor(b, group) != null;

  OutfitSlot _slotFor(Category category) {
    switch (category) {
      case Category.top:
        return OutfitSlot.top;
      case Category.bottom:
        return OutfitSlot.bottom;
      case Category.dress:
        return OutfitSlot.dress;
      case Category.shoes:
        return OutfitSlot.shoes;
      case Category.outerwear:
        return OutfitSlot.outerwear;
      case Category.accessory:
        return OutfitSlot.accessory;
    }
  }

  Set<Season> _specificSeasons(Iterable<Item> items) =>
      items.map((i) => i.season).where((s) => s != Season.all).toSet();

  bool _violatesSeasonGate(Set<Season> seasons) =>
      seasons.contains(Season.summer) && seasons.contains(Season.winter);

  String _colorName(Item item) =>
      item.colorPrimaryName ?? snapToNamedColor(item.colorPrimaryHex)?.name ?? item.colorPrimaryHex;
}

class _SlotColor {
  final Item item;
  final HsvColor hsv;

  const _SlotColor(this.item, this.hsv);
}

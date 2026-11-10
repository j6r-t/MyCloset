import 'package:flutter_test/flutter_test.dart';

import 'package:my_closet/models/enums.dart';
import 'package:my_closet/models/item.dart';
import 'package:my_closet/services/color_math.dart';
import 'package:my_closet/services/suggestion_engine.dart';

/// Table-driven tests for the rule-based suggestion engine
/// (docs/backend.md section 5).
Item _item(
  int id,
  Category category,
  String hex, {
  Season season = Season.all,
  String? colorName,
  LayerType? layerType,
}) {
  return Item(
    id: id,
    name: 'Item $id',
    category: category,
    season: season,
    colorPrimaryHex: hex,
    colorPrimaryName: colorName,
    layerType: layerType,
    imagePath: 'original.jpg',
    cutoutPath: 'cutout.png',
    createdAt: DateTime(2026, 1, 1),
  );
}

const engine = SuggestionEngine();

PairScore _pair(String hexA, String hexB) {
  final rgbA = hexToRgb(hexA)!;
  final rgbB = hexToRgb(hexB)!;
  return engine.scorePair(
    rgbToHsv(rgbA[0], rgbA[1], rgbA[2]),
    rgbToHsv(rgbB[0], rgbB[1], rgbB[2]),
  );
}

void main() {
  group('pair harmony rules (backend.md 5.2 table)', () {
    test('table of known pairs', () {
      // (hex A, hex B, expected score, expected rule)
      const cases = <(String, String, int, String)>[
        // Monochrome: circular hue distance < 20.
        ('#FF4040', '#FF2020', 6, 'monochrome'),
        // Analogous: 20 <= d < 50.
        ('#FF0000', '#FF6000', 7, 'analogous'), // h 0 vs h ~22
        // Complementary: d in [150, 180].
        ('#FF0000', '#00FFFF', 9, 'complementary'),
        ('#1C2B4A', '#E1AD01', 9, 'complementary'), // navy + mustard
        // Split-complementary / triadic: 100 <= d < 150 (circular distance
        // folds the spec's 210-260 band onto the same range).
        ('#FF0000', '#0000FF', 7, 'split-complementary'), // d = 120
        ('#FFFF00', '#00FFFF', 7, 'split-complementary'), // d = 120
        // Neutral + accent: either saturation < 0.18.
        ('#8A8A8A', '#FF0000', 8, 'neutral-accent'),
        ('#F5EFDC', '#808000', 8, 'neutral-accent'), // cream + olive
        // Clash: d in [50, 100).
        ('#FF0000', '#FFFF00', 2, 'clash'), // d = 60
        ('#FF8000', '#80FF00', 2, 'clash'), // h 30 vs h 90
      ];

      for (final (hexA, hexB, expectedScore, expectedRule) in cases) {
        final result = _pair(hexA, hexB);
        expect(result.score, expectedScore,
            reason: '$hexA + $hexB score');
        expect(result.rule, expectedRule,
            reason: '$hexA + $hexB rule');
      }
    });

    test('achromatic colors carry no hue, so hue rules cannot match', () {
      // Grey (neutral) vs cyan: complementary requires a hue distance,
      // which an achromatic color does not have; the pair is neutral-accent.
      final result = _pair('#8A8A8A', '#00FFFF');
      expect(result.score, 8);
      expect(result.rule, 'neutral-accent');
    });
  });

  group('outfit scoring penalties (backend.md 5.2)', () {
    test('base outfit with no penalties scores 25', () {
      final breakdown = engine.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#FF0000', colorName: 'red'),
        OutfitSlot.bottom: _item(2, Category.bottom, '#66CCCC'), // muted cyan
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      });
      expect(breakdown.pairTotal, 25); // 9 + 8 + 8
      expect(breakdown.penalties, 0);
      expect(breakdown.total, 25);
    });

    test('two loud primaries take -4, one loud does not', () {
      final twoLoud = engine.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#FF0000'),
        OutfitSlot.bottom: _item(2, Category.bottom, '#00FFFF'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      });
      expect(twoLoud.penalties, -4);
      expect(twoLoud.total, 21);

      final oneLoud = engine.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#FF0000'), // loud
        OutfitSlot.bottom: _item(2, Category.bottom, '#3A5A7A'), // muted
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      });
      expect(oneLoud.penalties, 0);
      expect(oneLoud.total, 25);
    });

    test('3+ chromatic colors cost -3 each beyond two', () {
      // All primaries saturated (s = 0.5 >= 0.18) but not loud (s < 0.55),
      // so only the chromatic-count penalty applies: 5 colors = -9.
      final breakdown = engine.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#CC6666'),
        OutfitSlot.bottom: _item(2, Category.bottom, '#CC8A66'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#66CC8A'),
        OutfitSlot.outerwear: _item(4, Category.outerwear, '#8A66CC'),
        OutfitSlot.accessory: _item(5, Category.accessory, '#CCCC66'),
      });
      expect(breakdown.penalties, -9);
    });

    test('accessory season mismatch costs -2', () {
      final slots = {
        OutfitSlot.top: _item(1, Category.top, '#FF0000',
            season: Season.summer),
        OutfitSlot.bottom: _item(2, Category.bottom, '#8A8A8A',
            season: Season.summer),
        OutfitSlot.shoes: _item(3, Category.shoes, '#4A4A4A',
            season: Season.summer),
      };
      expect(engine.scoreOutfit(slots).penalties, 0);

      final withMismatch = Map<OutfitSlot, Item>.of(slots)
        ..[OutfitSlot.accessory] = _item(4, Category.accessory, '#C0C0C0',
            season: Season.winter);
      expect(engine.scoreOutfit(withMismatch).penalties, -2);

      final matching = Map<OutfitSlot, Item>.of(slots)
        ..[OutfitSlot.accessory] = _item(4, Category.accessory, '#C0C0C0',
            season: Season.summer);
      expect(engine.scoreOutfit(matching).penalties, 0);
    });
  });

  group('book palette bonus (backend.md 5.3)', () {
    test('+5 and the reason names the pairing', () {
      const wada = SuggestionEngine(
        palettes: [
          PaletteGroup('wada-001', ['#1C2B4A', '#E1AD01', '#F5EFDC']),
        ],
      );
      final breakdown = wada.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#1C2B4A', colorName: 'navy'),
        OutfitSlot.bottom:
            _item(2, Category.bottom, '#E1AD01', colorName: 'mustard'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      });
      expect(breakdown.paletteBonus, 5);
      expect(breakdown.total, breakdown.pairTotal + breakdown.penalties + 5);
      expect(breakdown.reason, contains('Wada palette pairing'));
      expect(breakdown.reason, contains('navy'));
      expect(breakdown.reason, contains('mustard'));
    });

    test('no bonus with empty palettes', () {
      final breakdown = engine.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#1C2B4A'),
        OutfitSlot.bottom: _item(2, Category.bottom, '#E1AD01'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      });
      expect(breakdown.paletteBonus, 0);
    });
  });

  group('reasons (backend.md 5.4)', () {
    test('best pair generates the one-liner', () {
      final breakdown = engine.scoreOutfit({
        OutfitSlot.top: _item(1, Category.top, '#1C2B4A', colorName: 'navy'),
        OutfitSlot.bottom:
            _item(2, Category.bottom, '#E1AD01', colorName: 'mustard'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      });
      expect(breakdown.reason, 'navy + mustard - complementary accents');
    });
  });

  group('candidate generation (backend.md 5.1)', () {
    test('dress candidates never mix with top/bottom', () {
      final wardrobe = [
        _item(1, Category.dress, '#1C2B4A'),
        _item(2, Category.top, '#FF0000'),
        _item(3, Category.bottom, '#8A8A8A'),
        _item(4, Category.shoes, '#8A8A8A'),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions.length, 2); // dress+shoes and top+bottom+shoes
      for (final s in suggestions) {
        final hasDress = s.slots.containsKey(OutfitSlot.dress);
        final hasTorso = s.slots.containsKey(OutfitSlot.top) ||
            s.slots.containsKey(OutfitSlot.bottom);
        expect(hasDress, isNot(equals(hasTorso)),
            reason: 'dress must exclude top and bottom');
      }
    });

    test('shoes are part of every base candidate', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000'),
        _item(2, Category.bottom, '#00FFFF'),
      ];
      expect(engine.suggest(wardrobe), isEmpty);
    });

    test('summer-only and winter-only items never share a candidate', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000', season: Season.summer),
        _item(2, Category.bottom, '#00FFFF', season: Season.winter),
        _item(3, Category.shoes, '#8A8A8A'),
      ];
      expect(engine.suggest(wardrobe), isEmpty);
    });

    test('winter-only outerwear is not added to a summer candidate', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000', season: Season.summer),
        _item(2, Category.bottom, '#8A8A8A', season: Season.summer),
        _item(3, Category.shoes, '#8A8A8A', season: Season.summer),
        _item(4, Category.outerwear, '#1C2B4A', season: Season.winter),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(1));
      expect(
        suggestions.single.slots.containsKey(OutfitSlot.outerwear),
        isFalse,
      );
    });

    test('the best compatible outerwear wins', () {
      // Olive (not loud) beats loud yellow: both clash similarly with red,
      // but yellow triggers the two-loud-primaries penalty.
      final wardrobe = [
        _item(1, Category.top, '#FF0000', season: Season.summer),
        _item(2, Category.bottom, '#8A8A8A', season: Season.summer),
        _item(3, Category.shoes, '#8A8A8A', season: Season.summer),
        _item(4, Category.outerwear, '#FFFF00', season: Season.all),
        _item(5, Category.outerwear, '#808000', season: Season.all),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(1));
      expect(suggestions.single.slots[OutfitSlot.outerwear]!.id, 5);
    });

    test('season-conflicting accessory is allowed but penalized', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000', season: Season.summer),
        _item(2, Category.bottom, '#8A8A8A', season: Season.summer),
        _item(3, Category.shoes, '#8A8A8A', season: Season.summer),
        _item(4, Category.accessory, '#C0C0C0', season: Season.winter),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(1));
      expect(
        suggestions.single.slots.containsKey(OutfitSlot.accessory),
        isTrue,
      );
      expect(suggestions.single.breakdown.penalties, -2);
    });

    test('optional slots are dropped when every option lowers the score',
        () {
      // Constructed so adding the accessory strictly lowers the total:
      // the base has one loud primary and three chromatic colors; the loud
      // red accessory adds the two-loud penalty (-4) and a fourth chromatic
      // color (-3 extra), while all three new pairs clash (+6).
      final baseSlots = {
        OutfitSlot.top: _item(1, Category.top, '#FFFF00'), // loud yellow
        OutfitSlot.bottom: _item(2, Category.bottom, '#6F377A'), // muted
        OutfitSlot.shoes: _item(3, Category.shoes, '#643B7A'), // muted
      };
      final baseTotal = engine.scoreOutfit(baseSlots).total; // 17

      final withAccessory = Map<OutfitSlot, Item>.of(baseSlots)
        ..[OutfitSlot.accessory] = _item(4, Category.accessory, '#FF0000');
      expect(engine.scoreOutfit(withAccessory).total, 16); // 17 + 6 - 7
      expect(engine.scoreOutfit(withAccessory).total,
          lessThan(baseTotal));

      final wardrobe = [
        _item(1, Category.top, '#FFFF00'),
        _item(2, Category.bottom, '#6F377A'),
        _item(3, Category.shoes, '#643B7A'),
        _item(4, Category.accessory, '#FF0000'),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(1));
      expect(
        suggestions.single.slots.containsKey(OutfitSlot.accessory),
        isFalse,
      );
      expect(suggestions.single.breakdown.total, baseTotal);
    });
  });

  group('layering tops fill the outerwear slot (schema v2, backend.md 5.1)',
      () {
    test('a top with layerType outer can fill the outerwear slot', () {
      // Two layering tops, one bottom, shoes. The candidate wearing top 1
      // can layer top 2 over it as outerwear and vice versa.
      final wardrobe = [
        _item(1, Category.top, '#8A8A8A', layerType: LayerType.outer),
        _item(2, Category.top, '#4A4A4A', layerType: LayerType.outer),
        _item(3, Category.bottom, '#C0C0C0'),
        _item(4, Category.shoes, '#8A8A8A'),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, isNotEmpty);
      // Every suggestion layers one of the two tops over the other; the
      // layered piece is a top-category item sitting in the outerwear slot.
      final layered = suggestions
          .where((s) => s.slots.containsKey(OutfitSlot.outerwear))
          .toList();
      expect(layered, isNotEmpty);
      for (final s in layered) {
        expect(s.slots[OutfitSlot.outerwear]!.category, Category.top);
        // The same garment is never worn twice in one outfit.
        expect(
          s.slots[OutfitSlot.outerwear]!.id,
          isNot(equals(s.slots[OutfitSlot.top]!.id)),
        );
      }
    });

    test('layerType both qualifies a top for the outerwear slot too', () {
      final wardrobe = [
        _item(1, Category.top, '#8A8A8A', layerType: LayerType.both),
        _item(2, Category.top, '#4A4A4A', layerType: LayerType.both),
        _item(3, Category.bottom, '#C0C0C0'),
        _item(4, Category.shoes, '#8A8A8A'),
      ];
      final layered = engine
          .suggest(wardrobe)
          .where((s) => s.slots.containsKey(OutfitSlot.outerwear))
          .toList();
      expect(layered, isNotEmpty);
    });

    test('a plain top (null or inner layerType) never layers', () {
      final wardrobe = [
        _item(1, Category.top, '#8A8A8A'),
        _item(2, Category.top, '#4A4A4A', layerType: LayerType.inner),
        _item(3, Category.bottom, '#C0C0C0'),
        _item(4, Category.shoes, '#8A8A8A'),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, isNotEmpty);
      for (final s in suggestions) {
        expect(s.slots.containsKey(OutfitSlot.outerwear), isFalse);
      }
    });

    test('a layering top also fills the outerwear slot over a dress', () {
      final wardrobe = [
        _item(1, Category.dress, '#8A8A8A'),
        _item(2, Category.shoes, '#4A4A4A'),
        _item(3, Category.top, '#C0C0C0', layerType: LayerType.outer),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(1));
      expect(suggestions.single.slots[OutfitSlot.outerwear]!.id, 3);
    });

    test('real outerwear beats a layering top when it scores better', () {
      // Olive outerwear (neutral-accent with red, quiet) improves the base;
      // the loud yellow layering top would trigger the two-loud penalty.
      // The yellow layering top is still a valid top in its own right, so it
      // also generates its own base candidate.
      final wardrobe = [
        _item(1, Category.top, '#FF0000', season: Season.summer),
        _item(2, Category.bottom, '#8A8A8A', season: Season.summer),
        _item(3, Category.shoes, '#8A8A8A', season: Season.summer),
        _item(4, Category.outerwear, '#808000', season: Season.all),
        _item(5, Category.top, '#FFFF00',
            season: Season.all, layerType: LayerType.outer),
      ];
      final suggestions = engine.suggest(wardrobe);

      final redBase = suggestions
          .firstWhere((s) => s.slots[OutfitSlot.top]!.id == 1);
      // Olive beats the yellow layering top for the outerwear slot.
      expect(redBase.slots[OutfitSlot.outerwear]!.id, 4);

      final yellowBase = suggestions
          .firstWhere((s) => s.slots[OutfitSlot.top]!.id == 5);
      // The yellow top cannot layer over itself, but the olive outerwear
      // still improves this quiet-grey base.
      expect(yellowBase.slots[OutfitSlot.outerwear]!.id, 4);
    });

    test('season gate still applies to layering tops', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000', season: Season.summer),
        _item(2, Category.bottom, '#8A8A8A', season: Season.summer),
        _item(3, Category.shoes, '#8A8A8A', season: Season.summer),
        _item(4, Category.top, '#4A4A4A',
            season: Season.winter, layerType: LayerType.outer),
      ];
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(1));
      expect(
        suggestions.single.slots.containsKey(OutfitSlot.outerwear),
        isFalse,
      );
    });
  });

  group('ranking and shuffle (backend.md 5.4)', () {
    test('returns top 3 ranked by score, deduped', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000', colorName: 'red'),
        _item(2, Category.bottom, '#00FFFF', colorName: 'cyan'),
        _item(3, Category.top, '#8A8A8A'),
        _item(4, Category.bottom, '#C0C0C0'),
        _item(5, Category.shoes, '#4A4A4A'),
      ];
      // Four candidates exist. All three quiet combos (cyan with greys,
      // or all-neutral trios) score 24; the loud red+cyan combo scores 25
      // pair total minus 4 for two loud primaries = 21 and ranks last.
      final suggestions = engine.suggest(wardrobe);
      expect(suggestions, hasLength(3));
      for (var i = 1; i < suggestions.length; i++) {
        expect(
          suggestions[i].breakdown.total,
          lessThanOrEqualTo(suggestions[i - 1].breakdown.total),
        );
      }
      expect(suggestions.map((s) => s.key).toSet().length, 3);
      expect(suggestions[0].breakdown.total, 24);
      expect(suggestions[2].breakdown.total, 24);
    });

    test('exclude removes previously shown combos', () {
      final wardrobe = [
        _item(1, Category.top, '#FF0000'),
        _item(2, Category.bottom, '#00FFFF'),
        _item(3, Category.shoes, '#8A8A8A'),
        _item(4, Category.shoes, '#4A4A4A'),
      ];
      final first = engine.suggest(wardrobe);
      expect(first, hasLength(2));
      final second = engine.suggest(wardrobe, exclude: {first[0].key});
      expect(second, hasLength(1));
      expect(second.single.key, first[1].key);
    });
  });

  group('live harmony readout (backend.md 5.5)', () {
    test('harmonious: 3 pairs, no penalties', () {
      final slots = {
        OutfitSlot.top: _item(1, Category.top, '#FF0000'),
        OutfitSlot.bottom: _item(2, Category.bottom, '#66CCCC'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      }; // 25
      expect(engine.harmonyReadout(slots), HarmonyBucket.harmonious);
    });

    test('mixed: loud penalty lands in the middle bucket', () {
      final slots = {
        OutfitSlot.top: _item(1, Category.top, '#FF0000'),
        OutfitSlot.bottom: _item(2, Category.bottom, '#FFFF00'),
        OutfitSlot.shoes: _item(3, Category.shoes, '#8A8A8A'),
      }; // 18 pair total, -4 loud = 14
      expect(engine.harmonyReadout(slots), HarmonyBucket.mixed);
    });

    test('clashing: a single quiet pair is below the threshold', () {
      final slots = {
        OutfitSlot.dress: _item(1, Category.dress, '#FF0000'),
        OutfitSlot.shoes: _item(2, Category.shoes, '#8A8A8A'),
      }; // one pair, 8
      expect(engine.harmonyReadout(slots), HarmonyBucket.clashing);
    });
  });
}

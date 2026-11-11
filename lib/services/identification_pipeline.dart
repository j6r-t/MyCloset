// Identification pipeline: orchestrates the opt-in online garment lookup
// (the app's ONLY networked feature - everything else stays offline-first).
//
// Cascade, per run:
//   1. SerpApi Google Lens over the local image, via the Image API upload
//      route (SerpApiService.lensSearchByUpload - see that file's header for
//      why the upload round-trip exists).
//   2. Only when Lens produced no matches AND on-device hints exist: a
//      text-mode SerpApi web search reading the shopping_results block
//      ("brand type category price"), for a price suggestion. Skipped on
//      invalid-key/quota failures (more calls cannot succeed either).
//   3. Cloud Vision WEB_DETECTION over the same image (accepts base64
//      content inline - the natural fit for local cutouts).
//   4. Nothing succeeded: a graceful, non-throwing "no identification
//      available" result whose notes carry each step's reason.
//
// Matches are deduped by URL across steps (SerpApi first - it keeps its
// order, Vision fills only new URLs). The result's suggested* fields are
// guesses for EMPTY form fields only; the UI never overwrites user-entered
// values. No API key is ever logged, stored outside app_settings, or passed
// anywhere except its own service call.

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/enums.dart';
import 'serpapi_service.dart';
import 'vision_web_service.dart';

// Re-exported so pipeline consumers (the details form) get the match type
// without importing the SerpApi file directly.
export 'serpapi_service.dart' show ApiFailure, IdentifiedMatch;

/// The whole run's outcome. Never throws; failures live in [notes].
///
/// [ok] is true only when at least one usable *suggestion* could be
/// extracted (a brand, subtype, size or price; the name rides along as a
/// corroboration of those). Raw matches without any extractable detail are
/// reported as not-ok - the UI's not-found outcome must trigger for them,
/// not a prefill that fills nothing. The
/// suggested* fields are guesses for EMPTY form fields only; the UI never
/// overwrites user-entered values.
class IdentificationResult {
  /// True when there is at least one usable suggestion (see the class doc).
  final bool ok;

  final List<IdentifiedMatch> matches;

  /// Item name guess: the best match's title, cleaned (site junk stripped,
  /// duplicated brand prefix dropped, capped at 40 chars).
  final String? suggestedName;

  /// Brand+model guess (SerpApi knowledge_graph title, else Vision's top
  /// web entity).
  final String? suggestedBrand;

  /// Finer type keyword-matched from the best title ('sneakers', 'hoodie',
  /// 'jeans'...), null when nothing in our dictionary hits.
  final String? suggestedSubtype;

  /// Layering role derived from [suggestedSubtype] when the subtype has a
  /// known layering behavior; null otherwise (the form keeps its category
  /// default).
  final LayerType? suggestedLayerType;

  /// Size token found in the best title ('M', '42'...), null when absent.
  final String? suggestedSize;

  /// Price string as the source wrote it ("$89.00").
  final String? suggestedPriceText;

  /// Parsed price number when available (shopping's extracted_price).
  final double? suggestedPriceValue;

  /// Not reliably derivable without a vision-language model; always null
  /// today (kept so the UI contract is stable - see docs/handoff.md
  /// backlog note on a future vision-LLM identification step; the new
  /// [suggestedSubtype] covers the keyword-matchable part).
  final String? suggestedType;

  /// One friendly line per step explaining what happened (used as the
  /// sheet's captions when [ok] is false, appended when partial).
  final List<String> notes;

  const IdentificationResult({
    required this.ok,
    required this.matches,
    this.suggestedName,
    this.suggestedBrand,
    this.suggestedSubtype,
    this.suggestedLayerType,
    this.suggestedSize,
    this.suggestedPriceText,
    this.suggestedPriceValue,
    this.suggestedType,
    required this.notes,
  });

  factory IdentificationResult.unavailable(List<String> notes) =>
      IdentificationResult(ok: false, matches: const [], notes: notes);
}

/// Which form field a suggestion targets.
enum IdentificationTarget { brand, subtype, price }

class IdentificationPipeline {
  final SerpApiService _serpApi;
  final VisionWebService _vision;

  /// Dependency injection for tests; production uses real HTTP clients.
  IdentificationPipeline({
    SerpApiService? serpApi,
    VisionWebService? vision,
  })  : _serpApi = serpApi ?? SerpApiService(),
        _vision = vision ?? VisionWebService();

  /// Runs the cascade over the image at [imagePath] (cutout preferred; the
  /// original works too). Hints come from the on-device form state.
  Future<IdentificationResult> identify({
    required String imagePath,
    String? categoryLabel,
    String? subtype,
    String? brand,
    String? serpApiKey,
    String? visionApiKey,
  }) async {
    final notes = <String>[];
    final serpKey = serpApiKey?.trim() ?? '';
    final visionKey = visionApiKey?.trim() ?? '';

    if (serpKey.isEmpty && visionKey.isEmpty) {
      return IdentificationResult.unavailable(const [
        'No API keys set. Add one in Settings > Online identification.',
      ]);
    }

    List<int> jpegBytes;
    try {
      final bytes = await File(imagePath).readAsBytes();
      jpegBytes = prepareIdentificationJpeg(bytes);
    } catch (_) {
      return IdentificationResult.unavailable(const [
        'Could not read the item image.',
      ]);
    }

    final matches = <IdentifiedMatch>[];
    String? brandSuggestion;
    IdentifiedMatch? shoppingTop;
    var serpFatalFailure = false;

    // Step 1 - SerpApi Google Lens.
    if (serpKey.isNotEmpty) {
      final lens = await _serpApi.lensSearchByUpload(
        jpegBytes: jpegBytes,
        apiKey: serpKey,
      );
      if (lens.failure != null && lens.matches.isEmpty) {
        notes.add(lens.failure!.message);
        serpFatalFailure = lens.failure!.kind == ApiErrorKind.invalidKey ||
            lens.failure!.kind == ApiErrorKind.quota;
      }
      matches.addAll(lens.matches);
      brandSuggestion = lens.knowledgeTitle?.trim().isNotEmpty == true
          ? lens.knowledgeTitle!.trim()
          : null;
    }

    // Step 2 - text-mode shopping lookup, only to salvage a price when Lens
    // found nothing and a hint exists.
    if (serpKey.isNotEmpty && !serpFatalFailure && matches.isEmpty) {
      final hintParts = [
        brand?.trim(),
        subtype?.trim(),
        categoryLabel?.trim(),
      ].where((p) => p != null && p.isNotEmpty).toList();
      if (hintParts.isNotEmpty) {
        final shopping = await _serpApi.shoppingSearch(
          query: '${hintParts.join(' ')} price',
          apiKey: serpKey,
        );
        if (shopping.failure != null) notes.add(shopping.failure!.message);
        shoppingTop = shopping.topResult;
      }
    }
    if (shoppingTop != null) {
      matches.add(shoppingTop);
      brandSuggestion ??= _brandFromShoppingTitle(shoppingTop.title, brand);
    }

    // Step 3 - Cloud Vision fallback.
    if (visionKey.isNotEmpty && matches.isEmpty) {
      final web = await _vision.webDetection(
        jpegBytes: jpegBytes,
        apiKey: visionKey,
      );
      if (web.failure != null && web.matches.isEmpty) {
        notes.add(web.failure!.message);
      }
      matches.addAll(web.matches);
      brandSuggestion ??= web.topEntity?.trim().isNotEmpty == true
          ? web.topEntity!.trim()
          : null;
    } else if (visionKey.isEmpty && matches.isEmpty) {
      notes.add('No Vision key set.');
    }

    final deduped = dedupeByUrl(matches);
    final bestTitle = deduped.isEmpty ? null : deduped.first.title;
    final suggestedName = nameFromTitle(bestTitle, brand: brandSuggestion);
    // Subtype comes from a vote across all titles (see [subtypeFromMatches]);
    // name and size still come from the single best title - names and sizes
    // are per-listing facts, while the garment type is shared by every
    // listing of the same product.
    final suggestedSubtype = subtypeFromMatches(deduped);
    final suggestedSize = sizeFromTitle(bestTitle);
    final suggestedLayerType = layerTypeFromSubtype(suggestedSubtype);

    // A bare title echo is not a suggestion: junk pages match Lens too, so
    // ok requires a signal we actually understand (brand, subtype, size or
    // price). suggestedName is only surfaced alongside one of those.
    final hasSuggestions =
        brandSuggestion != null ||
        shoppingTop?.priceValue != null ||
        suggestedSubtype != null ||
        suggestedSize != null;
    if (!hasSuggestions) {
      // Ok-but-empty is not ok (the user's reported bug): matches that carry
      // no extractable detail must land on the not-found outcome, not on a
      // prefill that fills nothing.
      if (deduped.isNotEmpty) {
        notes.add('No recognizable product details in the results.');
      }
      return IdentificationResult.unavailable(
        notes.isEmpty ? const ['No identification available.'] : notes,
      );
    }

    return IdentificationResult(
      ok: true,
      matches: deduped,
      suggestedName: suggestedName,
      suggestedBrand: brandSuggestion,
      suggestedSubtype: suggestedSubtype,
      suggestedLayerType: suggestedLayerType,
      suggestedSize: suggestedSize,
      suggestedPriceText: shoppingTop?.priceText,
      suggestedPriceValue: shoppingTop?.priceValue,
      suggestedType: null,
      notes: notes,
    );
  }

  /// First token of a shopping title that differs from the typed brand hint
  /// ("Adidas Campus 80s Shoes" + no hint -> "Adidas"); null when nothing
  /// usable. Deliberately conservative - one word only.
  String? _brandFromShoppingTitle(String title, String? brandHint) {
    final words =
        title.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final first = words.isEmpty ? null : words.first;
    if (first == null ||
        first.length < 2 ||
        (brandHint != null &&
            brandHint.trim().isNotEmpty &&
            first.toLowerCase() == brandHint.trim().toLowerCase())) {
      return null;
    }
    return first;
  }

  // ------------------------------------------------------------ extraction
  //
  // Best-effort garment signals pulled out of match titles (SerpApi Lens
  // visual_matches titles, Vision page titles / URL slugs, shopping titles).
  // All static and table-driven-tested; every helper returns null rather
  // than guessing when its input carries no signal.

  /// Ordered subtype dictionary: keyword -> canonical form fed to the
  /// details form. Matching is position-based ([subtypeFromTitle]: the hit
  /// earliest in the title wins, longer keywords win ties), so compounds
  /// like 'dress shirt' must be present as their own entries or the first
  /// word would win the position race.
  static const List<(String, String)> _subtypeDictionary = [
    // Compounds first (they only win via the length tie-break, but keeping
    // them documented here keeps the dictionary readable).
    ('t-shirt', 't-shirt'),
    ('dress shirt', 'shirt'),
    ('polo shirt', 'polo'),
    ('polo', 'polo'),
    ('turtleneck', 'turtleneck'),
    ('tank top', 'tank top'),
    ('cargo pants', 'cargo pants'),
    ('cargo trousers', 'cargo pants'),
    ('cargo shorts', 'cargo shorts'),
    ('track pants', 'track pants'),
    ('joggers', 'joggers'),
    ('leggings', 'leggings'),
    ('dress pants', 'trousers'),
    ('snow boots', 'boots'),
    ('ankle boots', 'boots'),
    ('chelsea boots', 'boots'),
    ('combat boots', 'boots'),
    ('hoodie', 'hoodie'),
    ('sweatshirt', 'sweatshirt'),
    ('sweater', 'sweater'),
    ('cardigan', 'cardigan'),
    ('blazer', 'blazer'),
    ('parka', 'parka'),
    ('puffer', 'puffer jacket'),
    ('windbreaker', 'windbreaker'),
    ('bomber', 'bomber jacket'),
    ('jeans', 'jeans'),
    ('denim', 'jeans'),
    ('trousers', 'trousers'),
    ('chinos', 'chinos'),
    ('shorts', 'shorts'),
    ('sneakers', 'sneakers'),
    ('sneaker', 'sneakers'),
    ('trainers', 'sneakers'),
    ('trainer', 'sneakers'),
    ('loafers', 'loafers'),
    ('oxfords', 'oxfords'),
    ('boots', 'boots'),
    ('sandals', 'sandals'),
    ('sandal', 'sandals'),
    ('slides', 'slides'),
    ('heels', 'heels'),
    ('flats', 'flats'),
    ('blouse', 'blouse'),
    ('overshirt', 'overshirt'),
    ('dress', 'dress'),
    ('jumpsuit', 'jumpsuit'),
    ('romper', 'romper'),
    ('overalls', 'overalls'),
    ('jacket', 'jacket'),
    ('coat', 'coat'),
    ('vest', 'vest'),
    ('suit', 'suit'),
    ('cap', 'cap'),
    ('beanie', 'beanie'),
    ('hat', 'hat'),
    ('sunglasses', 'sunglasses'),
    ('glasses', 'glasses'),
    ('watch', 'watch'),
    ('bracelet', 'bracelet'),
    ('necklace', 'necklace'),
    ('ring', 'ring'),
    ('earrings', 'earrings'),
    ('gloves', 'gloves'),
    ('tie', 'tie'),
    ('wallet', 'wallet'),
    ('belt', 'belt'),
    ('scarf', 'scarf'),
    ('backpack', 'backpack'),
    ('tote', 'tote bag'),
    ('bag', 'bag'),
    ('tshirt', 't-shirt'),
    ('tee', 't-shirt'),
    ('shirt', 'shirt'),
  ];

  /// Subtypes with a known layering role (docs/backend.md 2.1): torso
  /// knits layer over a tee (both), structured outer layers stay outer,
  /// shirts and dresses sit inner.
  static const Map<String, LayerType> _subtypeLayerTypes = {
    't-shirt': LayerType.inner,
    'tank top': LayerType.inner,
    'shirt': LayerType.inner,
    'polo': LayerType.inner,
    'blouse': LayerType.inner,
    'dress': LayerType.inner,
    'hoodie': LayerType.both,
    'sweatshirt': LayerType.both,
    'sweater': LayerType.both,
    'cardigan': LayerType.both,
    'turtleneck': LayerType.both,
    'overshirt': LayerType.both,
    'jacket': LayerType.outer,
    'coat': LayerType.outer,
    'blazer': LayerType.outer,
    'parka': LayerType.outer,
    'puffer jacket': LayerType.outer,
    'bomber jacket': LayerType.outer,
    'windbreaker': LayerType.outer,
    'vest': LayerType.outer,
  };

  /// Keyword-matches [title] against the subtype dictionary (word
  /// boundaries, case-insensitive). Position-based: the hit that appears
  /// earliest in the title wins, and on a shared position the longer
  /// keyword wins ('dress shirt' beats 'dress' at offset 0; 'cargo pants'
  /// beats 'pants'). Returns null when nothing hits.
  static String? subtypeFromTitle(String? title) {
    if (title == null) return null;
    final lower = title.toLowerCase();
    String? best;
    var bestPos = -1;
    var bestLen = -1;
    for (final (keyword, subtype) in _subtypeDictionary) {
      final escaped = keyword.replaceAll(' ', r'\s+');
      final match = RegExp('\\b$escaped\\b').firstMatch(lower);
      if (match == null) continue;
      final pos = match.start;
      final len = keyword.length;
      if (best == null || pos < bestPos || (pos == bestPos && len > bestLen)) {
        best = subtype;
        bestPos = pos;
        bestLen = len;
      }
    }
    return best;
  }

  /// Subtype consensus across ALL match titles, not just the first: each of
  /// the top [maxVotes] titles contributes its keyword hit, the first title
  /// counts double (the ranking put it first), and the highest score wins.
  /// Ties go to the subtype seen first. Returns null when no title hits.
  ///
  /// Voting exists because the single-first-title rule kept filling wrong
  /// types: one junk listing ("Men's Graphic Tee") outranking nine "Hoodie"
  /// results flipped the whole suggestion.
  static String? subtypeFromMatches(List<IdentifiedMatch> matches) {
    const maxVotes = 8;
    final scores = <String, int>{};
    for (var i = 0; i < matches.length && i < maxVotes; i++) {
      final subtype = subtypeFromTitle(matches[i].title);
      if (subtype == null) continue;
      scores[subtype] = (scores[subtype] ?? 0) + (i == 0 ? 2 : 1);
    }
    String? best;
    var bestScore = 0;
    for (final entry in scores.entries) {
      if (entry.value > bestScore) {
        best = entry.key;
        bestScore = entry.value;
      }
    }
    return best;
  }

  /// Maps [subtype] to its layering role, null for subtypes (or nulls)
  /// without a known role.
  static LayerType? layerTypeFromSubtype(String? subtype) =>
      subtype == null ? null : _subtypeLayerTypes[subtype];

  /// Size token in [title]: a standalone letter size (XS|S|M|L|XL|XXL), or
  /// a "size 42"-style European number (30-59). Null when absent.
  static String? sizeFromTitle(String? title) {
    if (title == null) return null;
    final letter = RegExp(r'\b(XS|S|M|L|XL|XXL)\b').firstMatch(title);
    if (letter != null) return letter.group(1);
    // European numeric sizes: "size 42", "eu 42", "42 eu" (case-insensitive,
    // sane range so year numbers and prices do not slip in).
    for (final pattern in const [
      r'\bsize\s*:?\s*(\d{2})\b',
      r'\beu\s*:?\s*(\d{2})\b',
      r'\b(\d{2})\s*eu\b',
    ]) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(title);
      if (match != null) {
        final value = int.parse(match.group(1)!);
        if (value >= 30 && value <= 59) return match.group(1);
      }
    }
    return null;
  }

  /// Cleans [title] into an item-name suggestion: trailing site junk
  /// (" | Shop", " - Store") stripped, a leading brand duplicate dropped
  /// (never below two words), capped at 40 chars on a word boundary.
  /// Null when nothing usable remains.
  static String? nameFromTitle(String? title, {String? brand}) {
    if (title == null) return null;
    var name = title.trim();
    if (name.isEmpty) return null;

    // Trailing pipe junk ("adidas Campus | Zalando").
    final pipe = name.indexOf('|');
    if (pipe > 0) name = name.substring(0, pipe);

    // Trailing dash junk ("Campus 80s - END."): strip the tail only when
    // it looks like a store label (1-2 tokens, none numeric).
    final dash = RegExp(r'\s+[-–]\s+(\S+(?:\s+\S+)?)$').firstMatch(name);
    if (dash != null) {
      final tail = dash.group(1)!;
      final tailTokens = tail.split(RegExp(r'\s+'));
      final numericTail = tailTokens.any((t) => RegExp(r'\d').hasMatch(t));
      if (!numericTail) name = name.substring(0, dash.start);
    }

    // Brand prefix duplication ("adidas Campus 00s sneakers" with brand
    // "Adidas" -> "Campus 00s sneakers"). Only the first token goes, and
    // only when at least two words remain.
    final brandFirst = brand?.trim().split(RegExp(r'\s+')).first;
    if (brandFirst != null && brandFirst.isNotEmpty) {
      final tokens =
          name.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
      if (tokens.length > 2 &&
          tokens.first.toLowerCase() == brandFirst.toLowerCase()) {
        name = tokens.skip(1).join(' ');
      }
    }

    name = name.trim();
    if (name.length > 40) {
      name = name.substring(0, 40);
      final lastSpace = name.lastIndexOf(' ');
      if (lastSpace >= 20) name = name.substring(0, lastSpace);
      name = name.trim();
    }
    return name.isEmpty ? null : name;
  }

  /// Keeps the first occurrence of each URL (case-insensitive), preserving
  /// step order. SerpApi shopping entries use product_link, so real
  /// duplicates only arise across steps.
  static List<IdentifiedMatch> dedupeByUrl(List<IdentifiedMatch> matches) {
    final seen = <String>{};
    final result = <IdentifiedMatch>[];
    for (final match in matches) {
      final key = match.url.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      result.add(match);
    }
    return result;
  }

  /// Decodes any supported image and re-encodes as JPEG, longest edge
  /// downscaled to ~512px (Cloud Vision's sweet spot; also under SerpApi's
  /// 500 KB upload cap for any plausible 512px JPEG). Returns the original
  /// bytes unchanged when decoding fails - the APIs accept most inputs.
  static List<int> prepareIdentificationJpeg(List<int> bytes) {
    try {
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) return bytes;
      final longEdge =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      var small = decoded;
      if (longEdge > 512) {
        final scale = 512 / longEdge;
        small = img.copyResize(
          decoded,
          width: (decoded.width * scale).round(),
          height: (decoded.height * scale).round(),
        );
      }
      return img.encodeJpg(small, quality: 85);
    } catch (_) {
      return bytes;
    }
  }
}

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

import 'serpapi_service.dart';
import 'vision_web_service.dart';

// Re-exported so pipeline consumers (the details form) get the match type
// without importing the SerpApi file directly.
export 'serpapi_service.dart' show ApiFailure, IdentifiedMatch;

/// The whole run's outcome. Never throws; failures live in [notes].
class IdentificationResult {
  /// True when there is anything to offer (matches or suggestions).
  final bool ok;

  final List<IdentifiedMatch> matches;

  /// Brand+model guess (SerpApi knowledge_graph title, else Vision's top
  /// web entity).
  final String? suggestedBrand;

  /// Price string as the source wrote it ("$89.00").
  final String? suggestedPriceText;

  /// Parsed price number when available (shopping's extracted_price).
  final double? suggestedPriceValue;

  /// Not reliably derivable without a vision-language model; always null
  /// today (kept so the UI contract is stable - see docs/handoff.md
  /// backlog note on a future vision-LLM identification step).
  final String? suggestedType;

  /// One friendly line per step explaining what happened (used as the
  /// sheet's captions when [ok] is false, appended when partial).
  final List<String> notes;

  const IdentificationResult({
    required this.ok,
    required this.matches,
    this.suggestedBrand,
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
    final hasSuggestions =
        brandSuggestion != null || shoppingTop?.priceValue != null;
    if (deduped.isEmpty && !hasSuggestions) {
      return IdentificationResult.unavailable(notes.isEmpty
          ? const ['No identification available.']
          : notes);
    }

    return IdentificationResult(
      ok: true,
      matches: deduped,
      suggestedBrand: brandSuggestion,
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

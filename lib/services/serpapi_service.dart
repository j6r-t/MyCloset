// SerpApi client for the opt-in online identification feature.
//
// Contract notes (verified against the live docs 2026-11-10):
//
// - engine=google_lens (https://serpapi.com/google-lens-api) accepts exactly
//   two image inputs: `url` (a PUBLIC image URL) or `image_id`. There is no
//   base64 / data-URI parameter, and google_reverse_images is URL-only too,
//   so a local cutout cannot be passed directly to either engine.
// - The supported route for local images is SerpApi's Image API
//   (https://serpapi.com/image-api): POST https://serpapi.com/image with
//   multipart/form-data, fields `image` (binary JPG/PNG/WebP, max 500 KB)
//   and `api_key`. The response JSON carries an `image_id` (expires after
//   10 minutes - we use it immediately) that google_lens accepts via the
//   `image_id` parameter. Uploading plus searching may consume two search
//   credits on quota-limited plans.
// - google_lens responses carry `visual_matches` (title, link, source,
//   thumbnail, ...) and sometimes a `knowledge_graph` with a `title`.
// - Google Shopping results (https://serpapi.com/shopping-results) come back
//   under `shopping_results` with fields `title`, `price` (string),
//   `extracted_price` (number), `product_link`, `source`, `thumbnail`.
//
// The service never throws through its interface: every failure is mapped to
// an [ApiFailure] with a friendly message. Keys are only ever passed in from
// app_settings at runtime - never logged, never persisted anywhere else.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Why an API call failed, at the granularity the UI needs.
enum ApiErrorKind {
  /// Missing, malformed, or rejected API key.
  invalidKey,

  /// Plan quota exhausted or rate limited.
  quota,

  /// Timeout, no connectivity, DNS/socket failure.
  network,

  /// The call succeeded but found nothing usable.
  noResults,

  /// Anything else (unexpected response shape, server error...).
  other,
}

/// A mapped failure with a user-facing message (no raw response bodies, no
/// keys).
class ApiFailure {
  final ApiErrorKind kind;
  final String message;

  const ApiFailure(this.kind, this.message);

  @override
  String toString() => 'ApiFailure(${kind.name}: $message)';
}

/// One clean web match, normalized across SerpApi and Cloud Vision.
class IdentifiedMatch {
  final String title;

  /// Money string exactly as the source returned it ("$89.00"), when known.
  final String? priceText;

  /// Parsed price number, when the source exposed one (shopping's
  /// `extracted_price`).
  final double? priceValue;

  /// Human source label ("Nike.com" or a hostname).
  final String source;

  final String url;

  /// Which pipeline step produced this: 'serpapi' or 'vision'.
  final String sourceTag;

  const IdentifiedMatch({
    required this.title,
    this.priceText,
    this.priceValue,
    required this.source,
    required this.url,
    required this.sourceTag,
  });
}

/// Shared response-parsing and error-mapping helpers for the identification
/// services.
class IdentificationApi {
  /// Network timeout for every identification call.
  static const Duration timeout = Duration(seconds: 15);

  IdentificationApi._();

  /// Maps a transport/HTTP outcome to an [ApiFailure]. [bodyText] is only
  /// inspected for error keywords - never stored or logged.
  static ApiFailure failureFor({
    required Object error,
    int? statusCode,
    String? bodyText,
  }) {
    if (error is ApiFailure) return error;
    if (error is TimeoutException ||
        error is http.ClientException ||
        error is SocketException) {
      return const ApiFailure(
        ApiErrorKind.network,
        'No connection. Check your network and try again.',
      );
    }
    final body = bodyText ?? '';
    if (statusCode == 401 || statusCode == 403) {
      final quota = body.toLowerCase().contains('quota') ||
          body.toLowerCase().contains('billing');
      if (quota) return _quota;
      return const ApiFailure(
        ApiErrorKind.invalidKey,
        'The API key was rejected. Check it in Settings.',
      );
    }
    if (statusCode == 429) return _quota;
    return const ApiFailure(
      ApiErrorKind.other,
      'The lookup failed. Try again later.',
    );
  }

  static const ApiFailure _quota = ApiFailure(
    ApiErrorKind.quota,
    'The API plan quota is used up for now.',
  );

  /// Maps a JSON body that carries SerpApi's top-level `error` string.
  static ApiFailure? serpErrorBody(String bodyText) {
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map && decoded['error'] is String) {
        final message = decoded['error'] as String;
        final lower = message.toLowerCase();
        if (lower.contains('api key')) {
          return const ApiFailure(
            ApiErrorKind.invalidKey,
            'The API key was rejected. Check it in Settings.',
          );
        }
        if (lower.contains('exhaust') ||
            lower.contains('quota') ||
            lower.contains('rate limit') ||
            lower.contains('plan')) {
          return _quota;
        }
        return ApiFailure(ApiErrorKind.other, 'The lookup failed: $message');
      }
    } catch (_) {
      // Not JSON - fall through.
    }
    return null;
  }

  /// "https://shop.example.com/nike-air-max-90.html" -> "air max 90".
  /// Falls back to the host when the path carries nothing usable.
  static String titleFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final segments =
        uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    for (final segment in segments.reversed) {
      final withoutExtension = segment.replaceFirst(RegExp(r'\.\w+$'), '');
      final words = withoutExtension
          .split(RegExp(r'[-_+\s]+'))
          .where((w) => w.trim().isNotEmpty && w != 'index')
          .toList();
      if (words.length >= 2) {
        final joined = words.join(' ');
        return joined[0].toUpperCase() + joined.substring(1);
      }
    }
    return uri.host.replaceFirst(RegExp(r'^www\.'), '');
  }

  /// Host of a URL without the "www." prefix; the raw string when unparseable.
  static String hostOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host.replaceFirst(RegExp(r'^www\.'), '');
  }
}

/// Result of one Google Lens lookup via the Image API upload route.
class SerpLensResult {
  final List<IdentifiedMatch> matches;

  /// `knowledge_graph.title` when present (usually brand + model, e.g.
  /// "Adidas Campus") - the pipeline offers it as a brand suggestion.
  final String? knowledgeTitle;

  final ApiFailure? failure;

  const SerpLensResult({
    required this.matches,
    this.knowledgeTitle,
    this.failure,
  });
}

/// Result of one text-mode Google search's shopping block.
class SerpShoppingResult {
  /// First shopping result that carried a price, if any.
  final IdentifiedMatch? topResult;

  final ApiFailure? failure;

  const SerpShoppingResult({this.topResult, this.failure});
}

class SerpApiService {
  final http.Client _client;

  SerpApiService({http.Client? client}) : _client = client ?? http.Client();

  static const _base = 'https://serpapi.com';

  /// Google Lens for a LOCAL image: uploads the (already downscaled) JPEG to
  /// the Image API, then runs engine=google_lens with the returned image_id.
  /// Never throws; see the file header for why this two-step route exists.
  Future<SerpLensResult> lensSearchByUpload({
    required List<int> jpegBytes,
    required String apiKey,
  }) async {
    // Step 1: upload, get an image_id.
    String? imageId;
    try {
      final request = http.MultipartRequest('POST', Uri.parse('$_base/image'))
        ..fields['api_key'] = apiKey
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            jpegBytes,
            filename: 'cutout.jpg',
          ),
        );
      final streamed = await _client
          .send(request)
          .timeout(IdentificationApi.timeout);
      final response = await http.Response.fromStream(streamed);
      imageId = _imageIdFrom(response.body);
      if (imageId == null) {
        final mapped = IdentificationApi.serpErrorBody(response.body) ??
            IdentificationApi.failureFor(
              error: 'missing image_id',
              statusCode: response.statusCode,
            );
        return SerpLensResult(matches: const [], failure: mapped);
      }
    } catch (e) {
      return SerpLensResult(
        matches: const [],
        failure: IdentificationApi.failureFor(error: e),
      );
    }

    // Step 2: lens search with the image_id (expires after 10 minutes -
    // used immediately here).
    try {
      final uri = Uri.parse('$_base/search.json').replace(queryParameters: {
        'engine': 'google_lens',
        'api_key': apiKey,
        'image_id': imageId,
      });
      final response = await _client
          .get(uri)
          .timeout(IdentificationApi.timeout);
      final body = response.body;
      final bodyError = IdentificationApi.serpErrorBody(body);
      if (bodyError != null) {
        return SerpLensResult(matches: const [], failure: bodyError);
      }
      if (response.statusCode != 200) {
        return SerpLensResult(
          matches: const [],
          failure: IdentificationApi.failureFor(
            error: 'http ${response.statusCode}',
            statusCode: response.statusCode,
            bodyText: body,
          ),
        );
      }
      return _parseLens(body);
    } catch (e) {
      return SerpLensResult(
        matches: const [],
        failure: IdentificationApi.failureFor(error: e),
      );
    }
  }

  String? _imageIdFrom(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final id = decoded['image_id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } catch (_) {
      // Non-JSON upload response handled by the caller.
    }
    return null;
  }

  /// Parses visual_matches (+ knowledge_graph) from a google_lens JSON body.
  SerpLensResult _parseLens(String body) {
    final matches = <IdentifiedMatch>[];
    String? knowledgeTitle;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final graph = decoded['knowledge_graph'];
        if (graph is Map) {
          final title = graph['title'];
          if (title is String && title.isNotEmpty) knowledgeTitle = title;
        }
        final visual = decoded['visual_matches'];
        if (visual is List) {
          for (final entry in visual) {
            if (entry is! Map) continue;
            final link = entry['link'];
            if (link is! String || link.isEmpty) continue;
            final source = entry['source'];
            matches.add(
              IdentifiedMatch(
                title: (entry['title'] as String?)?.isNotEmpty == true
                    ? entry['title'] as String
                    : IdentificationApi.titleFromUrl(link),
                source: source is String && source.isNotEmpty
                    ? source
                    : IdentificationApi.hostOf(link),
                url: link,
                sourceTag: 'serpapi',
              ),
            );
          }
        }
      }
    } catch (_) {
      // A malformed body yields no matches; the pipeline reports "no
      // results" rather than throwing (backend.md section 7 spirit).
    }
    return SerpLensResult(
      matches: matches,
      knowledgeTitle: knowledgeTitle,
    );
  }

  /// Text-mode lookup: engine=google web search, reading the
  /// `shopping_results` block. Used by the pipeline when on-device hints
  /// (brand/type) exist but the lens path produced no matches. Query string
  /// is built from user-entered data only.
  Future<SerpShoppingResult> shoppingSearch({
    required String query,
    required String apiKey,
  }) async {
    try {
      final uri = Uri.parse('$_base/search.json').replace(queryParameters: {
        'engine': 'google',
        'device': 'desktop',
        'q': query,
        'api_key': apiKey,
      });
      final response = await _client
          .get(uri)
          .timeout(IdentificationApi.timeout);
      final bodyError = IdentificationApi.serpErrorBody(response.body);
      if (bodyError != null) {
        return SerpShoppingResult(failure: bodyError);
      }
      if (response.statusCode != 200) {
        return SerpShoppingResult(
          failure: IdentificationApi.failureFor(
            error: 'http ${response.statusCode}',
            statusCode: response.statusCode,
            bodyText: response.body,
          ),
        );
      }
      return SerpShoppingResult(topResult: _parseShopping(response.body));
    } catch (e) {
      return SerpShoppingResult(
        failure: IdentificationApi.failureFor(error: e),
      );
    }
  }

  IdentifiedMatch? _parseShopping(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final shopping = decoded['shopping_results'];
      if (shopping is! List) return null;
      for (final entry in shopping) {
        if (entry is! Map) continue;
        final link = entry['product_link'];
        if (link is! String || link.isEmpty) continue;
        final priceValue = entry['extracted_price'];
        return IdentifiedMatch(
          title: entry['title'] is String && (entry['title'] as String).isNotEmpty
              ? entry['title'] as String
              : IdentificationApi.titleFromUrl(link),
          priceText: entry['price'] is String ? entry['price'] as String : null,
          priceValue: priceValue is num ? priceValue.toDouble() : null,
          source: entry['source'] is String && (entry['source'] as String).isNotEmpty
              ? entry['source'] as String
              : IdentificationApi.hostOf(link),
          url: link,
          sourceTag: 'serpapi',
        );
      }
    } catch (_) {
      // Malformed body -> no result.
    }
    return null;
  }
}

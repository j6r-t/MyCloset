// Google Cloud Vision WEB_DETECTION client for the opt-in online
// identification feature.
//
// Contract notes (verified against the Cloud Vision images:annotate API):
//
// - Endpoint: POST https://vision.googleapis.com/v1/images:annotate?key=<key>
//   The API key travels as a query parameter (documented Google flow for
//   API-key auth on Vision).
// - The image is sent inline as base64 in `image.content`; Vision accepts
//   this directly, which is exactly why it works for our local-only cutouts
//   where SerpApi's Lens engine needs an upload round-trip.
// - Response: responses[0].webDetection with `pagesWithMatchingImages`
//   (items: `pageUrl`, `pageTitle`, `fullMatchingImages`/`partialMatchingImages`
//   lists of `{url}`), `visuallySimilarImages` (items: `title`, `url`) and
//   `webEntities` (items: `description`, `score`).
// - Errors come back as HTTP 4xx/5xx with `{error: {code, message, status}}`;
//   an invalid or restricted key is 400/403, quota is 429.
//
// The service never throws through its interface: every failure maps to an
// [ApiFailure]. Keys arrive from app_settings at runtime only - never
// hardcoded, logged, or persisted anywhere else.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'serpapi_service.dart' show ApiErrorKind, ApiFailure, IdentifiedMatch,
    IdentificationApi;

/// Result of one Vision web-detection call.
class VisionWebResult {
  final List<IdentifiedMatch> matches;

  /// Description of the highest-scoring web entity, when any ("Nike",
  /// "Sneakers"...) - a guess the pipeline may offer as a brand suggestion.
  final String? topEntity;

  final ApiFailure? failure;

  const VisionWebResult({
    required this.matches,
    this.topEntity,
    this.failure,
  });
}

class VisionWebService {
  final http.Client _client;

  VisionWebService({http.Client? client}) : _client = client ?? http.Client();

  static const _endpoint = 'https://vision.googleapis.com/v1/images:annotate';

  /// WEB_DETECTION over an inline (already downscaled) JPEG. Never throws.
  Future<VisionWebResult> webDetection({
    required List<int> jpegBytes,
    required String apiKey,
  }) async {
    final uri = Uri.parse('$_endpoint?key=$apiKey');
    final payload = jsonEncode({
      'requests': [
        {
          'image': {'content': base64Encode(jpegBytes)},
          'features': [
            {'type': 'WEB_DETECTION', 'maxResults': 10},
          ],
        },
      ],
    });

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(IdentificationApi.timeout);
    } catch (e) {
      return VisionWebResult(
        matches: const [],
        failure: IdentificationApi.failureFor(error: e),
      );
    }

    if (response.statusCode != 200) {
      return VisionWebResult(
        matches: const [],
        failure: _mapHttpError(response.statusCode, response.body),
      );
    }

    final matches = <IdentifiedMatch>[];
    String? topEntity;
    try {
      final decoded = jsonDecode(response.body);
      final responses = decoded is Map ? decoded['responses'] : null;
      if (responses is List && responses.isNotEmpty) {
        final first = responses.first;
        final detection = first is Map ? first['webDetection'] : null;
        if (detection is Map) {
          matches.addAll(_parsePages(detection));
          matches.addAll(_parseSimilar(detection));
          topEntity = _topEntity(detection);
        }
      }
    } catch (_) {
      // Malformed body -> no matches; reported as no results below.
    }
    if (matches.isEmpty && topEntity == null) {
      return VisionWebResult(
        matches: matches,
        failure: const ApiFailure(
          ApiErrorKind.noResults,
          'Nothing recognizable found online for this piece.',
        ),
      );
    }
    return VisionWebResult(matches: matches, topEntity: topEntity);
  }

  /// pagesWithMatchingImages -> one match per page (title from pageTitle,
  /// else guessed from the URL slug).
  List<IdentifiedMatch> _parsePages(Map detection) {
    final matches = <IdentifiedMatch>[];
    final pages = detection['pagesWithMatchingImages'];
    if (pages is! List) return matches;
    for (final page in pages) {
      if (page is! Map) continue;
      final pageUrl = page['pageUrl'];
      if (pageUrl is! String || pageUrl.isEmpty) continue;
      final pageTitle = page['pageTitle'];
      matches.add(
        IdentifiedMatch(
          title: pageTitle is String && pageTitle.trim().isNotEmpty
              ? pageTitle.trim()
              : IdentificationApi.titleFromUrl(pageUrl),
          source: IdentificationApi.hostOf(pageUrl),
          url: pageUrl,
          sourceTag: 'vision',
        ),
      );
    }
    return matches;
  }

  /// visuallySimilarImages -> matches whose URL is the image itself; the
  /// title (when Google has one) or the URL slug names the garment.
  List<IdentifiedMatch> _parseSimilar(Map detection) {
    final matches = <IdentifiedMatch>[];
    final similar = detection['visuallySimilarImages'];
    if (similar is! List) return matches;
    for (final entry in similar) {
      if (entry is! Map) continue;
      final url = entry['url'];
      if (url is! String || url.isEmpty) continue;
      final title = entry['title'];
      matches.add(
        IdentifiedMatch(
          title: title is String && title.trim().isNotEmpty
              ? title.trim()
              : IdentificationApi.titleFromUrl(url),
          source: IdentificationApi.hostOf(url),
          url: url,
          sourceTag: 'vision',
        ),
      );
    }
    return matches;
  }

  /// Highest-scoring entity with a description.
  String? _topEntity(Map detection) {
    final entities = detection['webEntities'];
    if (entities is! List) return null;
    String? best;
    var bestScore = -1.0;
    for (final entity in entities) {
      if (entity is! Map) continue;
      final description = entity['description'];
      if (description is! String || description.trim().isEmpty) continue;
      final score = entity['score'];
      final value = score is num ? score.toDouble() : 0.0;
      if (value > bestScore) {
        bestScore = value;
        best = description.trim();
      }
    }
    return best;
  }

  ApiFailure _mapHttpError(int statusCode, String body) {
    // Extract error.message for keyword mapping; the body is not stored.
    var message = body;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final raw = decoded['error']['message'];
        if (raw is String) message = raw;
      }
    } catch (_) {
      // Keep the raw body for keyword checks.
    }
    return IdentificationApi.failureFor(
      error: 'http $statusCode',
      statusCode: statusCode,
      bodyText: message,
    );
  }
}

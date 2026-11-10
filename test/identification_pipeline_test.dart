// Online identification pipeline orchestration (mocked HTTP, fixture JSON
// bodies built from the documented response shapes):
// - SerpApi Lens success (upload + image_id search);
// - SerpApi failure -> Cloud Vision fallback;
// - both fail -> graceful non-throwing result;
// - URL dedupe across steps;
// - no keys -> immediate unavailable result, no HTTP at all.
// No real key material appears anywhere in this file - fixtures use a
// synthetic placeholder that never leaves the test process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:my_closet/services/identification_pipeline.dart';
import 'package:my_closet/services/serpapi_service.dart';
import 'package:my_closet/services/vision_web_service.dart';

/// Test-only placeholder key. Never a real credential.
const _testKey = 'test-key-placeholder';

/// Records requests and answers from a scripted table so the tests can
/// assert which endpoints the pipeline actually hit.
class _FakeClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) handler;
  final requests = <http.BaseRequest>[];

  _FakeClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

http.Response _json(Object body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// A real 8x8 JPEG so the pipeline's downscale step decodes it.
List<int> _jpegBytes() {
  final image = img.Image(width: 8, height: 8);
  for (final pixel in image) {
    pixel..r = 180..g = 60..b = 40;
  }
  return img.encodeJpg(image);
}

Future<File> _tempImage() async {
  final dir = await Directory.systemTemp.createTemp('mycloset_id_');
  final file = File('${dir.path}${Platform.pathSeparator}cutout.png');
  await file.writeAsBytes(_jpegBytes());
  return file;
}

// Fixture JSON built from the documented shapes (serpapi.com/google-lens-api:
// visual_matches[] with title/link/source; serpapi.com/shopping-results:
// shopping_results[] with title/price/extracted_price/product_link/source;
// Cloud Vision webDetection: pagesWithMatchingImages[].pageUrl,
// visuallySimilarImages[].url|title, webEntities[].description/score).

const _serpUploadOk = {'image_id': 'img_123'};

Map<String, Object> _lensBody({bool withKnowledge = true}) => {
      'search_metadata': {'status': 'Success'},
      if (withKnowledge)
        'knowledge_graph': {'title': 'Adidas Campus'},
      'visual_matches': [
        {
          'position': 1,
          'title': 'adidas Campus 00s sneakers',
          'link': 'https://www.adidas.com/us/campus-00s-shoes/IG2996.html',
          'source': 'adidas.com',
          'thumbnail': 'https://serpapi.com/thumbs/a.webp',
        },
        {
          'position': 2,
          'title': 'Campus 80s - END.',
          'link': 'https://www.endclothing.com/us/adidas-campus-80s',
          'source': 'END.',
          'thumbnail': 'https://serpapi.com/thumbs/b.webp',
        },
      ],
    };

Map<String, Object> _visionBody({bool duplicate = false}) => {
      'responses': [
        {
          'webDetection': {
            'pagesWithMatchingImages': [
              {
                'pageUrl': 'https://sneakernews.com/2024/01/adidas-campus-review',
                'pageTitle': 'adidas Campus review',
                'fullMatchingImages': [
                  {'url': 'https://sneakernews.com/img/campus.jpg'},
                ],
              },
            ],
            'visuallySimilarImages': [
              {
                'url': 'https://img.example.com/adidas-campus-00s-white.jpg',
              },
              if (duplicate)
                {'url': 'https://img.example.com/adidas-campus-00s-white.jpg'},
            ],
            'webEntities': [
              {'description': 'Adidas', 'score': 0.91},
              {'description': 'Sneakers', 'score': 0.74},
            ],
          },
        },
      ],
    };

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mycloset_pipe_');
  });

  tearDown(() async {
    if (await tempDir.exists()) tempDir.deleteSync(recursive: true);
  });

  group('pipeline orchestration', () {
    test('serpapi success: upload + image_id lens search produce matches',
        () async {
      final image = await _tempImage();
      var uploadCalls = 0;
      final client = _FakeClient((request) async {
        final url = request.url.toString();
        if (request is http.MultipartRequest &&
            url.startsWith('https://serpapi.com/image')) {
          uploadCalls++;
          return _json(_serpUploadOk);
        }
        if (url.startsWith('https://serpapi.com/search.json')) {
          expect(request.url.queryParameters['engine'], 'google_lens');
          expect(request.url.queryParameters['image_id'], 'img_123');
          return _json(_lensBody());
        }
        fail('unexpected request: $url');
      });

      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: client),
        vision: VisionWebService(client: client),
      );
      final result = await pipeline.identify(
        imagePath: image.path,
        serpApiKey: _testKey,
      );

      expect(uploadCalls, 1);
      expect(result.ok, isTrue);
      expect(result.matches, hasLength(2));
      expect(result.matches.every((m) => m.sourceTag == 'serpapi'), isTrue);
      expect(result.matches.first.title, 'adidas Campus 00s sneakers');
      expect(result.suggestedBrand, 'Adidas Campus');
      // Lens succeeded: the shopping salvage step never ran.
      expect(
        client.requests.where((r) =>
            r.url.queryParameters['engine'] == 'google'),
        isEmpty,
      );
      // The key was sent to SerpApi endpoints only; nothing else in the
      // request set.
      expect(client.requests, hasLength(2));
    });

    test('serpapi failure -> vision fallback produces vision-tagged matches',
        () async {
      final image = await _tempImage();
      final client = _FakeClient((request) async {
        final url = request.url.toString();
        if (url.startsWith('https://serpapi.com/image')) {
          return http.Response('unauthorized', 401);
        }
        if (url.startsWith('https://vision.googleapis.com')) {
          expect(request.method, 'POST');
          final body = jsonDecode(utf8.decode((request as http.Request).bodyBytes))
              as Map<String, Object?>;
          final request0 = (body['requests'] as List).first as Map;
          expect(
            (request0['features'] as List).first,
            containsPair('type', 'WEB_DETECTION'),
          );
          expect(request0['image'], containsPair('content', isNotNull));
          return _json(_visionBody());
        }
        fail('unexpected request: $url');
      });

      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: client),
        vision: VisionWebService(client: client),
      );
      final result = await pipeline.identify(
        imagePath: image.path,
        serpApiKey: _testKey,
        visionApiKey: _testKey,
      );

      expect(result.ok, isTrue);
      expect(
        result.matches.every((m) => m.sourceTag == 'vision'),
        isTrue,
      );
      expect(result.matches, isNotEmpty);
      // pagesWithMatchingImages + visuallySimilarImages minus dedupe.
      expect(result.matches, hasLength(2));
      // Title guessed from the URL slug when Google gives none.
      expect(
        result.matches.last.title,
        contains('campus 00s white'),
      );
      // Vision's top entity becomes the brand guess (no knowledge_graph).
      expect(result.suggestedBrand, 'Adidas');
      // The step's rejection is reported in the notes.
      expect(
        result.notes.any((n) => n.contains('rejected')),
        isTrue,
      );
    });

    test('both fail -> graceful result, no throw, reasons in notes',
        () async {
      final image = await _tempImage();
      final client = _FakeClient((request) async {
        final url = request.url.toString();
        if (url.startsWith('https://serpapi.com/image')) {
          return http.Response('unauthorized', 401);
        }
        if (url.startsWith('https://vision.googleapis.com')) {
          return _json({
            'error': {
              'code': 429,
              'message': 'Quota exceeded',
              'status': 'RESOURCE_EXHAUSTED',
            },
          }, status: 429);
        }
        fail('unexpected request: $url');
      });

      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: client),
        vision: VisionWebService(client: client),
      );
      final result = await pipeline.identify(
        imagePath: image.path,
        serpApiKey: _testKey,
        visionApiKey: _testKey,
      );

      expect(result.ok, isFalse);
      expect(result.matches, isEmpty);
      expect(result.notes, isNotEmpty);
    });

    test('lens returns nothing + hints -> shopping salvage offers a price',
        () async {
      final image = await _tempImage();
      final client = _FakeClient((request) async {
        final url = request.url.toString();
        if (url.startsWith('https://serpapi.com/image')) {
          return _json(_serpUploadOk);
        }
        if (url.startsWith('https://serpapi.com/search.json')) {
          final engine = request.url.queryParameters['engine'];
          if (engine == 'google_lens') {
            return _json({
              'search_metadata': {'status': 'Success'},
              // No visual_matches: Lens found nothing.
            });
          }
          if (engine == 'google') {
            expect(request.url.queryParameters['device'], 'desktop');
            final q = request.url.queryParameters['q']!;
            expect(q, contains('Adidas'));
            expect(q, contains('sneakers'));
            return _json({
              'shopping_results': [
                {
                  'title': 'Adidas Campus 00s Shoes',
                  'price': '\$89.00',
                  'extracted_price': 89.0,
                  'product_link':
                      'https://www.google.com/shopping/product/123',
                  'source': 'adidas.com',
                },
              ],
            });
          }
        }
        fail('unexpected request: $url');
      });

      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: client),
        vision: VisionWebService(client: client),
      );
      final result = await pipeline.identify(
        imagePath: image.path,
        categoryLabel: 'shoes',
        subtype: 'sneakers',
        brand: 'Adidas',
        serpApiKey: _testKey,
      );

      expect(result.ok, isTrue);
      expect(result.suggestedPriceValue, 89.0);
      expect(result.suggestedPriceText, '\$89.00');
      expect(result.suggestedType, isNull);
    });

    test('matches are deduped by URL across steps', () async {
      final image = await _tempImage();
      final client = _FakeClient((request) async {
        final url = request.url.toString();
        if (url.startsWith('https://serpapi.com/image')) {
          return _json(_serpUploadOk);
        }
        if (url.startsWith('https://serpapi.com/search.json')) {
          final engine = request.url.queryParameters['engine'];
          if (engine == 'google_lens') {
            return _json({
              'visual_matches': [
                {
                  'title': 'Same page',
                  'link': 'https://sneakernews.com/adidas-campus-review',
                  'source': 'Sneaker News',
                },
              ],
            });
          }
          return _json({'shopping_results': []});
        }
        if (url.startsWith('https://vision.googleapis.com')) {
          // Same page URL, different casing - must be dropped.
          return _json(_visionBody(duplicate: true));
        }
        fail('unexpected request: $url');
      });

      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: client),
        vision: VisionWebService(client: client),
      );
      final result = await pipeline.identify(
        imagePath: image.path,
        serpApiKey: _testKey,
        visionApiKey: _testKey,
      );

      final urls = result.matches.map((m) => m.url.toLowerCase()).toSet();
      expect(urls.length, result.matches.length);
    });

    test('no keys set -> immediate graceful result, zero HTTP', () async {
      final image = await _tempImage();
      final client = _FakeClient((request) async {
        fail('no request should be made without keys');
      });

      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: client),
        vision: VisionWebService(client: client),
      );
      final result = await pipeline.identify(imagePath: image.path);

      expect(result.ok, isFalse);
      expect(result.notes.single, contains('No API keys set'));
      expect(client.requests, isEmpty);
    });

    test('unreadable image path -> graceful result', () async {
      final pipeline = IdentificationPipeline(
        serpApi: SerpApiService(client: _FakeClient((r) async => _json({}))),
        vision: VisionWebService(client: _FakeClient((r) async => _json({}))),
      );
      final result = await pipeline.identify(
        imagePath: '${tempDir.path}${Platform.pathSeparator}missing.png',
        serpApiKey: _testKey,
        visionApiKey: _testKey,
      );
      expect(result.ok, isFalse);
      expect(result.notes.single, contains('image'));
    });
  });

  group('downscale', () {
    test('prepareIdentificationJpeg caps the long edge near 512', () {
      final big = img.Image(width: 1600, height: 800);
      final bytes = img.encodeJpg(big);
      final prepared = IdentificationPipeline.prepareIdentificationJpeg(bytes);
      final decoded =
          img.decodeImage(Uint8List.fromList(prepared))!;
      expect(decoded.width, lessThanOrEqualTo(512));
      expect(decoded.height, lessThanOrEqualTo(512));
    });
  });
}

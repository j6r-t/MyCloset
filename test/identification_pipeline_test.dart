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

import 'package:my_closet/models/enums.dart';
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
    test('serpapi success: upload + image_id lens search produce matches, '
        'then a shopping lookup fills the price', () async {
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
          final engine = request.url.queryParameters['engine'];
          if (engine == 'google_lens') {
            expect(request.url.queryParameters['image_id'], 'img_123');
            return _json(_lensBody());
          }
          // The success path now also runs the shopping lookup (query from
          // the identified title) so the Value field fills too.
          if (engine == 'google') {
            final q = request.url.queryParameters['q']!;
            expect(q, contains('Campus 00s sneakers'));
            expect(q, contains('price'));
            return _json({
              'shopping_results': [
                {
                  'title': 'adidas Campus 00s Shoes',
                  'price': '\$110.00',
                  'extracted_price': 110.0,
                  'product_link': 'https://www.adidas.com/us/campus-00s',
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
        serpApiKey: _testKey,
      );

      expect(uploadCalls, 1);
      expect(result.ok, isTrue);
      // Lens matches stay first; the shopping entry is appended.
      expect(result.matches, hasLength(3));
      expect(result.matches.first.title, 'adidas Campus 00s sneakers');
      expect(
        result.matches.every((m) => m.sourceTag == 'serpapi'),
        isTrue,
      );
      expect(result.suggestedBrand, 'Adidas Campus');
      expect(result.suggestedPriceValue, 110.0);
      expect(result.suggestedPriceText, '\$110.00');
      // Upload + lens search + shopping search.
      expect(client.requests, hasLength(3));
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

  group('ok semantics (backend.md 5b)', () {
    test('matches without any extractable detail are NOT ok', () async {
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
                  'title': 'Check out our summer sale now',
                  'link': 'https://shop.example.com/summer-sale',
                  'source': 'shop.example.com',
                },
                {
                  'title': 'About us | Fashion Blog',
                  'link': 'https://blog.example.com/about',
                  'source': 'blog.example.com',
                },
              ],
            });
          }
          // The price-salvage lookup now runs on this path too; it finds
          // nothing usable and must not flip the outcome to ok.
          return _json({'shopping_results': []});
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

      // The user-reported bug: ok-but-empty must land on the not-found
      // outcome so the screen shows it instead of a bare details form.
      expect(result.ok, isFalse);
      expect(result.matches, isEmpty);
      expect(
        result.notes.any(
          (n) => n.contains('No recognizable product details'),
        ),
        isTrue,
      );
    });

    test('lens success fills name, subtype, size and layer type', () async {
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
              'knowledge_graph': {'title': 'Adidas'},
              'visual_matches': [
                {
                  'title': 'Adidas Campus 00s sneakers size 42',
                  'link': 'https://www.adidas.com/us/campus-00s',
                  'source': 'adidas.com',
                },
              ],
            });
          }
          return _json({'shopping_results': []});
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

      expect(result.ok, isTrue);
      expect(result.suggestedName, 'Campus 00s sneakers size 42');
      expect(result.suggestedBrand, 'Adidas');
      expect(result.suggestedSubtype, 'sneakers');
      expect(result.suggestedLayerType, isNull);
      expect(result.suggestedSize, '42');
    });
  });

  group('title extraction (table-driven)', () {
    test('subtypeFromTitle: earliest title position wins, compounds beat '
        'their head word', () {
      final cases = <String, String?>{
        'Adidas Campus 00s sneakers size 42': 'sneakers',
        'MCM red hoodie': 'hoodie',
        'Nike Sportswear Club Fleece sweatshirt': 'sweatshirt',
        'Levi\'s 501 Original jeans': 'jeans',
        'Men\'s Oxford shirt': 'shirt',
        'Classic Polo': 'polo',
        'Wool winter coat': 'coat',
        'Cargo pants beige': 'cargo pants',
        'Summer floral dress': 'dress',
        'Leather belt brown': 'belt',
        // 'dress shirt' must win the position tie against 'dress'.
        'Blue dress shirt slim fit': 'shirt',
        // 'trench coat' has no jacket keyword, so coat wins on position.
        'Vintage trench coat': 'coat',
        'Check out our summer sale now': null,
        '': null,
      };
      cases.forEach((title, expected) {
        expect(IdentificationPipeline.subtypeFromTitle(title), expected,
            reason: 'title: $title');
      });
      expect(IdentificationPipeline.subtypeFromTitle(null), isNull);
    });

    test('subtypeFromMatches votes across titles instead of trusting the '
        'first', () {
      IdentifiedMatch m(String title) => IdentifiedMatch(
            title: title,
            source: 'test',
            url: 'https://example.com/${title.hashCode}',
            sourceTag: 'serpapi',
          );
      // One junk tee listing first, nine hoodie listings after: the vote
      // must land on hoodie (old behavior took the first title's tee).
      final matches = [
        m('Men\'s Graphic Tee'),
        for (var i = 0; i < 9; i++) m('Fleece hoodie $i'),
      ];
      expect(IdentificationPipeline.subtypeFromMatches(matches), 'hoodie');
      // No hits at all -> null.
      expect(IdentificationPipeline.subtypeFromMatches([m('Summer sale')]),
          isNull);
      expect(IdentificationPipeline.subtypeFromMatches(const []), isNull);
    });

    test('brandFromTitle: dictionary hits, earliest position wins', () {
      final cases = <String, String?>{
        'Nike Air Max 90 Men\'s Shoes': 'Nike',
        'adidas Campus 00s sneakers': 'Adidas',
        'Levi\'s 501 Original jeans': "Levi's",
        'New Balance 574 sneakers': 'New Balance',
        'The North Face puffer jacket': 'The North Face',
        'H&M hoodie': 'H&M',
        'Campus 00s sneakers': null,
        'Check out our summer sale now': null,
        '': null,
      };
      cases.forEach((title, expected) {
        expect(IdentificationPipeline.brandFromTitle(title), expected,
            reason: 'title: $title');
      });
      expect(IdentificationPipeline.brandFromTitle(null), isNull);
    });

    test('brandFromMatches votes across titles like the subtype vote', () {
      IdentifiedMatch m(String title) => IdentifiedMatch(
            title: title,
            source: 'test',
            url: 'https://example.com/${title.hashCode}',
            sourceTag: 'serpapi',
          );
      // A knowledge_graph-less Lens run: titles still lead with the brand,
      // so the vote fills what the form's Brand row used to miss.
      final matches = [
        m('Air Max 90 sneakers'),
        m('Nike Air Max 90 white'),
        m('Nike Air Max 90 triple black'),
        m('Nike Sportswear tee'),
      ];
      expect(IdentificationPipeline.brandFromMatches(matches), 'Nike');
      // No dictionary hit anywhere -> null, never a bare-token guess.
      expect(
        IdentificationPipeline.brandFromMatches([m('Campus 00s sneakers')]),
        isNull,
      );
      expect(IdentificationPipeline.brandFromMatches(const []), isNull);
    });

    test('layerTypeFromSubtype maps the layering vocabulary', () {
      final cases = <String, LayerType?>{
        't-shirt': LayerType.inner,
        'shirt': LayerType.inner,
        'polo': LayerType.inner,
        'dress': LayerType.inner,
        'hoodie': LayerType.both,
        'sweatshirt': LayerType.both,
        'sweater': LayerType.both,
        'jacket': LayerType.outer,
        'coat': LayerType.outer,
        'blazer': LayerType.outer,
        'sneakers': null,
        'jeans': null,
      };
      cases.forEach((subtype, expected) {
        expect(IdentificationPipeline.layerTypeFromSubtype(subtype), expected,
            reason: 'subtype: $subtype');
      });
      expect(IdentificationPipeline.layerTypeFromSubtype(null), isNull);
    });

    test('sizeFromTitle: letter and European numeric tokens', () {
      final cases = <String, String?>{
        'Adidas Campus 00s sneakers size 42': '42',
        'Nike tee size M': 'M',
        'Slim fit blazer XL': 'XL',
        'Eu 40 leather boots': '40',
        'Adidas Samba white': null,
        'One size scarf': null, // no standalone size token
        'MCM red hoodie': null,
      };
      cases.forEach((title, expected) {
        expect(IdentificationPipeline.sizeFromTitle(title), expected,
            reason: 'title: $title');
      });
      expect(IdentificationPipeline.sizeFromTitle(null), isNull);
    });

    test('nameFromTitle strips junk, brand prefix, and caps at 40 chars',
        () {
      final cases = <String, String?>{
        'Adidas Campus 00s sneakers size 42': 'Campus 00s sneakers size 42',
        'campus 80s - END.': 'campus 80s',
        'Adidas Samba | Zalando': 'Adidas Samba',
        'MCM red hoodie': 'MCM red hoodie',
        'Adidas Campus 00s sneakers': 'Campus 00s sneakers',
        'Check out our summer sale now': 'Check out our summer sale now',
      };
      cases.forEach((title, expected) {
        expect(
          IdentificationPipeline.nameFromTitle(title, brand: 'Adidas'),
          expected,
          reason: 'title: $title',
        );
      });
      // A 2-word title keeps both words even when the brand repeats.
      expect(
        IdentificationPipeline.nameFromTitle('Adidas Campus',
            brand: 'Adidas'),
        'Adidas Campus',
      );
      // Longer than 40 chars: cut on a word boundary.
      final long = IdentificationPipeline.nameFromTitle(
        'Premium Handcrafted Artisanal Leather Sneaker Edition Collection',
        brand: null,
      );
      expect(long!.length, lessThanOrEqualTo(40));
      expect(long, isNot(endsWith(' ')));
      expect(IdentificationPipeline.nameFromTitle(null), isNull);
      expect(IdentificationPipeline.nameFromTitle('   '), isNull);
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

    test('prepareIdentificationJpeg flattens transparency onto white', () {
      // A cutout-shaped RGBA image: opaque red garment center, fully
      // transparent (black-rgb) corners. JPEG cannot carry alpha, so the
      // corners must come out WHITE after the round-trip - not black (the
      // plain alpha drop), which made Lens see a black rectangle.
      final image = img.Image(width: 40, height: 40, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
      for (var y = 10; y < 30; y++) {
        for (var x = 10; x < 30; x++) {
          image.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }
      final prepared = IdentificationPipeline.prepareIdentificationJpeg(
        Uint8List.fromList(img.encodePng(image)),
      );
      final decoded = img.decodeImage(Uint8List.fromList(prepared))!;
      final corner = decoded.getPixel(2, 2);
      expect(corner.r, greaterThan(230), reason: 'corner must be near white');
      expect(corner.g, greaterThan(230), reason: 'corner must be near white');
      expect(corner.b, greaterThan(230), reason: 'corner must be near white');
      final center = decoded.getPixel(20, 20);
      expect(center.r, greaterThan(200), reason: 'garment pixel stays red');
    });
  });

  group('category mapping', () {
    test('categoryFromSubtype covers the six categories', () {
      final cases = <String, Category>{
        'hoodie': Category.top,
        't-shirt': Category.top,
        'jeans': Category.bottom,
        'joggers': Category.bottom,
        'dress': Category.dress,
        'jumpsuit': Category.dress,
        'sneakers': Category.shoes,
        'boots': Category.shoes,
        'slides': Category.shoes,
        'jacket': Category.outerwear,
        'puffer jacket': Category.outerwear,
        'belt': Category.accessory,
        'backpack': Category.accessory,
      };
      cases.forEach((subtype, expected) {
        expect(IdentificationPipeline.categoryFromSubtype(subtype), expected,
            reason: 'subtype: $subtype');
      });
      expect(IdentificationPipeline.categoryFromSubtype('unknown thing'),
          isNull);
      expect(IdentificationPipeline.categoryFromSubtype(null), isNull);
    });
  });
}

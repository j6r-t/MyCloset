// Identification probe: runs the EXACT production identification pipeline
// (and the color extractor) over a local image from the command line, so
// enrichment quality can be tested without driving the app.
//
// Usage (from the project root):
//
//   dart run tool/identify_probe.dart <image.jpg|png> [options]
//
// Options:
//   --serpapi KEY    SerpApi key (falls back to $SERPAPI_KEY)
//   --vision KEY     Cloud Vision key (falls back to $VISION_KEY)
//   --no-colors      skip the color extraction report
//   --no-lookup      skip the online lookup (color report only)
//
// What it prints:
//   1. The prepared JPEG size actually uploaded (pipeline's own prep).
//   2. RAW SerpApi Google Lens visual_matches - every result the search
//      returned, unfiltered.
//   3. The full pipeline result (all cascade steps, same code path as the
//      app) with its step notes.
//   4. The decision trace: per match title, what the extraction helpers
//      see (subtype hit, size token, cleaned name) and the subtype vote
//      tally - that is how "the picked" happens.
//   5. The color report: merged k-means clusters with their sample share
//      and snapped names.
//
// Everything imports the production services directly; nothing here is a
// reimplementation, so probe output always reflects real app behavior.

// A command-line tool's whole job is printing to stdout.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:image/image.dart' as img;

import '../lib/data/named_colors.dart';
import '../lib/services/color_extraction_service.dart';
import '../lib/services/identification_pipeline.dart';
import '../lib/services/serpapi_service.dart';

const _usage =
    'Usage: dart run tool/identify_probe.dart <image> '
    '[--serpapi KEY] [--vision KEY] [--no-colors] [--no-lookup]';

Future<void> main(List<String> args) async {
  final flags = <String>{};
  final values = <String, String>{};
  String? imagePath;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--no-colors' || arg == '--no-lookup') {
      flags.add(arg);
    } else if (arg == '--serpapi' || arg == '--vision') {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value after $arg. $_usage');
        exitCode = 2;
        return;
      }
      values[arg] = args[++i];
    } else if (arg.startsWith('--')) {
      stderr.writeln('Unknown option $arg. $_usage');
      exitCode = 2;
      return;
    } else if (imagePath == null) {
      imagePath = arg;
    } else {
      stderr.writeln('Unexpected extra argument "$arg". $_usage');
      exitCode = 2;
      return;
    }
  }
  if (imagePath == null) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  final file = File(imagePath);
  if (!file.existsSync()) {
    stderr.writeln('No such file: $imagePath');
    exitCode = 2;
    return;
  }

  final serpKey =
      values['--serpapi'] ?? Platform.environment['SERPAPI_KEY'] ?? '';
  final visionKey =
      values['--vision'] ?? Platform.environment['VISION_KEY'] ?? '';

  final bytes = file.readAsBytesSync();
  final prepared = IdentificationPipeline.prepareIdentificationJpeg(bytes);
  _hr('Image');
  print('source: $imagePath (${bytes.length} bytes)');
  print('prepared upload: ${prepared.length} bytes '
      '(JPEG, longest edge <= 512)');

  if (!flags.contains('--no-colors')) {
    await _colorReport(file);
  }

  if (flags.contains('--no-lookup')) return;
  if (serpKey.isEmpty && visionKey.isEmpty) {
    _hr('Lookup skipped');
    print('No SerpApi/Vision key given. Pass --serpapi KEY / --vision KEY '
        'or set SERPAPI_KEY / VISION_KEY.');
    return;
  }

  // Raw Lens dump first: what the search actually returned, before any of
  // the pipeline's extraction logic runs.
  if (serpKey.isNotEmpty) {
    final lens = await SerpApiService().lensSearchByUpload(
      jpegBytes: prepared,
      apiKey: serpKey,
    );
    _hr('RAW SerpApi Google Lens results');
    if (lens.failure != null) print('failure: ${lens.failure!.message}');
    if (lens.knowledgeTitle != null) {
      print('knowledge_graph title: ${lens.knowledgeTitle}');
    }
    if (lens.matches.isEmpty) {
      print('(no visual_matches)');
    } else {
      for (var i = 0; i < lens.matches.length; i++) {
        final m = lens.matches[i];
        print('\n[${i + 1}] ${m.title}');
        print('    source: ${m.source}');
        print('    url:    ${m.url}');
        if (m.priceText != null) print('    price:  ${m.priceText}');
      }
    }
  }

  // The production pipeline end-to-end (same call the app makes).
  final pipeline = IdentificationPipeline();
  final result = await pipeline.identify(
    imagePath: imagePath,
    serpApiKey: serpKey.isEmpty ? null : serpKey,
    visionApiKey: visionKey.isEmpty ? null : visionKey,
  );

  _hr('Pipeline decision trace');
  for (final note in result.notes) {
    print('note: $note');
  }
  if (result.matches.isEmpty) {
    print('(no matches survived the cascade)');
  } else {
    print('per-title extraction (the inputs to the decision):\n');
    final scores = <String, int>{};
    for (var i = 0; i < result.matches.length && i < 8; i++) {
      final m = result.matches[i];
      final subtype = IdentificationPipeline.subtypeFromTitle(m.title);
      final size = IdentificationPipeline.sizeFromTitle(m.title);
      final name = IdentificationPipeline.nameFromTitle(m.title);
      if (subtype != null && i < 8) {
        scores[subtype] = (scores[subtype] ?? 0) + (i == 0 ? 2 : 1);
      }
      print('[${i + 1}] ${m.title}');
      print('    subtype: ${subtype ?? '-'}   size: ${size ?? '-'}');
      print('    name guess: ${name ?? '-'}');
    }
    print('\nsubtype vote tally: $scores');
  }

  _hr('Final suggestions (what the app would prefill)');
  String? show(String? v) => v ?? '-';
  print('ok:        ${result.ok}');
  print('name:      ${show(result.suggestedName)}');
  print('brand:     ${show(result.suggestedBrand)}');
  print('subtype:   ${show(result.suggestedSubtype)}');
  print('layer:     ${result.suggestedLayerType?.name ?? '-'}');
  print('size:      ${show(result.suggestedSize)}');
  print('price:     ${show(result.suggestedPriceText)} '
      '(${result.suggestedPriceValue ?? "-"})');
}

Future<void> _colorReport(File file) async {
  _hr('Color extraction report');
  final decoded = img.decodeImage(file.readAsBytesSync());
  if (decoded == null) {
    print('(image could not be decoded)');
    return;
  }
  final small = decoded.width > 320
      ? img.copyResize(decoded, width: 320)
      : decoded;
  final report = const ColorExtractionService().extractWithDiagnostics(small);
  if (report.clusters.isEmpty) {
    print('(no opaque pixels - nothing to extract)');
    return;
  }
  print('merged clusters (largest first):\n');
  for (var i = 0; i < report.clusters.length; i++) {
    final c = report.clusters[i];
    final named = snapToNamedColor(c.hex)?.name ?? '-';
    print('[${i + 1}] ${c.hex}  "$named"  '
        'share: ${(c.share * 100).toStringAsFixed(1)}%');
  }
  final e = report.extracted;
  print('\nprimary:   ${e.primaryHex ?? '-'} '
      '("${e.primaryName ?? "-"}")');
  print('secondary: ${e.secondaryHex ?? '-'} '
      '("${e.secondaryName ?? "-"}")');
}

void _hr(String title) {
  print('\n=== $title ${'=' * (60 - title.length.clamp(0, 60))}');
}

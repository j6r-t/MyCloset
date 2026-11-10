import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../data/named_colors.dart';
import 'color_math.dart';

/// Result of color extraction for one item cutout.
class ExtractedColors {
  /// Primary color as '#RRGGBB', or null when the cutout had no opaque
  /// pixels at all. Callers must still save the item (never block on
  /// extraction failure) and can substitute a neutral default.
  final String? primaryHex;
  final String? primaryName;
  final String? secondaryHex;
  final String? secondaryName;

  const ExtractedColors({
    this.primaryHex,
    this.primaryName,
    this.secondaryHex,
    this.secondaryName,
  });
}

/// One k-means cluster in RGB space.
class _Cluster {
  List<int> centroid;
  int count;

  _Cluster(this.centroid, this.count);
}

/// Implements docs/backend.md section 4:
///
/// 1. Collect opaque pixels (alpha > 200), downsampled to at most 10k samples.
/// 2. k-means, k = 3, 8 iterations, in RGB space.
/// 3. Primary = largest cluster; secondary = the next-largest cluster whose
///    centroid is at least Delta E 40 (CIELAB) from the primary, otherwise
///    no secondary (plain item).
/// 4. Snap primary and secondary hexes to the curated named-color list by
///    nearest CIELAB distance.
///
/// Everything here is deterministic: the same cutout always yields the same
/// colors (no random seeding in the k-means init).
class ColorExtractionService {
  static const int maxSamples = 10000;
  static const int kMeansClusters = 3;
  static const int kMeansIterations = 8;
  static const double secondaryMinDeltaE = 40.0;
  static const int opaqueAlphaThreshold = 200;

  const ColorExtractionService();

  /// Extracts primary/secondary colors from an RGBA cutout image.
  ExtractedColors extract(img.Image cutout) {
    final samples = _collectSamples(cutout);
    if (samples.isEmpty) {
      return const ExtractedColors();
    }

    final clusters = _kMeans(samples);
    clusters.sort((a, b) => b.count.compareTo(a.count));

    final primaryCentroid = clusters.first.centroid;
    final primaryLab = rgbToLab(primaryCentroid[0], primaryCentroid[1], primaryCentroid[2]);

    List<int>? secondaryCentroid;
    for (var i = 1; i < clusters.length; i++) {
      final c = clusters[i].centroid;
      final lab = rgbToLab(c[0], c[1], c[2]);
      if (labDistance(primaryLab, lab) >= secondaryMinDeltaE) {
        secondaryCentroid = c;
        break;
      }
    }

    final primaryHex = rgbToHex(primaryCentroid[0], primaryCentroid[1], primaryCentroid[2]);
    final primaryName = snapToNamedColor(primaryHex)?.name;

    String? secondaryHex;
    String? secondaryName;
    if (secondaryCentroid != null) {
      secondaryHex = rgbToHex(secondaryCentroid[0], secondaryCentroid[1], secondaryCentroid[2]);
      secondaryName = snapToNamedColor(secondaryHex)?.name;
    }

    return ExtractedColors(
      primaryHex: primaryHex,
      primaryName: primaryName,
      secondaryHex: secondaryHex,
      secondaryName: secondaryName,
    );
  }

  /// Collects opaque pixels as RGB triples. When more than [maxSamples] opaque
  /// pixels exist, takes an evenly strided deterministic subset.
  List<List<int>> _collectSamples(img.Image cutout) {
    final opaque = <List<int>>[];
    for (final pixel in cutout) {
      if (pixel.a.toInt() > opaqueAlphaThreshold) {
        opaque.add([pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()]);
      }
    }
    if (opaque.length <= maxSamples) {
      return opaque;
    }
    final stride = (opaque.length / maxSamples).ceil();
    final sampled = <List<int>>[];
    for (var i = 0; i < opaque.length; i += stride) {
      sampled.add(opaque[i]);
    }
    return sampled;
  }

  /// Deterministic k-means: farthest-point initialization (first sample, then
  /// repeatedly the sample farthest from all chosen centroids), followed by
  /// [kMeansIterations] assignment/update rounds. Empty clusters are
  /// reseeded with the sample that is farthest from its assigned centroid.
  List<_Cluster> _kMeans(List<List<int>> samples) {
    final k = math.min(kMeansClusters, samples.length);

    // Farthest-point initialization.
    final centroids = <List<int>>[List<int>.from(samples[0])];
    final minDistance = List<double>.filled(
      samples.length,
      double.infinity,
    );
    while (centroids.length < k) {
      for (var i = 0; i < samples.length; i++) {
        final d = rgbDistance(samples[i], centroids.last);
        if (d < minDistance[i]) minDistance[i] = d;
      }
      var bestIndex = 0;
      var bestDistance = -1.0;
      for (var i = 0; i < samples.length; i++) {
        if (minDistance[i] > bestDistance) {
          bestDistance = minDistance[i];
          bestIndex = i;
        }
      }
      centroids.add(List<int>.from(samples[bestIndex]));
    }

    var clusters = centroids.map((c) => _Cluster(c, 0)).toList();

    for (var iteration = 0; iteration < kMeansIterations; iteration++) {
      final sums = List.generate(k, (_) => [0.0, 0.0, 0.0]);
      final counts = List<int>.filled(k, 0);
      final assignments = List<int>.filled(samples.length, 0);
      final assignmentDistance = List<double>.filled(samples.length, double.infinity);

      for (var i = 0; i < samples.length; i++) {
        var bestCluster = 0;
        var bestDistance = double.infinity;
        for (var c = 0; c < k; c++) {
          final d = rgbDistance(samples[i], clusters[c].centroid);
          if (d < bestDistance) {
            bestDistance = d;
            bestCluster = c;
          }
        }
        assignments[i] = bestCluster;
        assignmentDistance[i] = bestDistance;
        counts[bestCluster]++;
        final s = samples[i];
        final sum = sums[bestCluster];
        sum[0] += s[0];
        sum[1] += s[1];
        sum[2] += s[2];
      }

      for (var c = 0; c < k; c++) {
        if (counts[c] > 0) {
          clusters[c].centroid = [
            (sums[c][0] / counts[c]).round(),
            (sums[c][1] / counts[c]).round(),
            (sums[c][2] / counts[c]).round(),
          ];
        } else {
          // Reseed an empty cluster with the worst-fit sample.
          var worstIndex = 0;
          var worstDistance = -1.0;
          for (var i = 0; i < samples.length; i++) {
            if (assignmentDistance[i] > worstDistance) {
              worstDistance = assignmentDistance[i];
              worstIndex = i;
            }
          }
          clusters[c].centroid = List<int>.from(samples[worstIndex]);
        }
        clusters[c].count = counts[c];
      }
    }

    return clusters.where((c) => c.count > 0).toList();
  }
}

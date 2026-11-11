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

/// One k-means cluster: RGB centroid + pixel count.
class _Cluster {
  List<int> centroid;
  int count;

  _Cluster(this.centroid, this.count);
}

/// What [ColorExtractionService.extractWithDiagnostics] reports back: the
/// saved colors plus every post-merge cluster, so the identify probe (and
/// tests) can see WHY a color won instead of just the winner.
class ColorDiagnostics {
  final ExtractedColors extracted;

  /// Merged clusters, largest first: centroid '#RRGGBB' + share of all
  /// opaque samples (0.0-1.0).
  final List<({String hex, double share})> clusters;

  const ColorDiagnostics({required this.extracted, required this.clusters});
}

/// Implements docs/backend.md section 4:
///
/// 1. Collect opaque pixels (alpha > 200), downsampled to at most 10k samples.
/// 2. k-means, k = 3, 8 iterations, distance measured in CIELAB (perceptual:
///    an RGB-space k-means splits a mid-tone garment into a bright and a
///    shadow cluster that RGB math treats as far apart while Lab knows they
///    are nearly the same color).
/// 3. Merge clusters whose centroids sit within [mergeMinDeltaE] of a larger
///    cluster (weight by count) - folds highlight/shadow fragments of one
///    garment color back together.
/// 4. Primary = largest merged cluster; secondary = the next-largest cluster
///    whose centroid is at least Delta E 40 (CIELAB) from the primary,
///    otherwise no secondary (plain item).
/// 5. Snap primary and secondary hexes to the curated named-color list
///    (see snapToNamedColor for the naming rules).
///
/// Everything here is deterministic: the same cutout always yields the same
/// colors (no random seeding in the k-means init).
class ColorExtractionService {
  static const int maxSamples = 10000;
  static const int kMeansClusters = 3;
  static const int kMeansIterations = 8;
  static const double secondaryMinDeltaE = 40.0;

  /// Two cluster centroids closer than this in CIELAB are one garment color
  /// photographed under different light - merged in step 3.
  static const double mergeMinDeltaE = 15.0;

  static const int opaqueAlphaThreshold = 200;

  const ColorExtractionService();

  /// Extracts primary/secondary colors from an RGBA cutout image.
  ExtractedColors extract(img.Image cutout) =>
      extractWithDiagnostics(cutout).extracted;

  /// Same pipeline as [extract], but also returns the merged clusters and
  /// their sample share - the identify probe's color report.
  ColorDiagnostics extractWithDiagnostics(img.Image cutout) {
    final samples = _collectSamples(cutout);
    if (samples.isEmpty) {
      return const ColorDiagnostics(
        extracted: ExtractedColors(),
        clusters: [],
      );
    }

    // Precompute per-sample Lab once; every k-means distance and merge
    // comparison below works in Lab space.
    final sampleLabs = samples
        .map((s) => rgbToLab(s[0], s[1], s[2]))
        .toList(growable: false);

    final clusters = _kMeans(samples, sampleLabs);
    final merged = _mergeNearClusters(clusters);
    merged.sort((a, b) => b.count.compareTo(a.count));

    final total = merged.fold<int>(0, (sum, c) => sum + c.count);
    final diagnostics = [
      for (final c in merged)
        (
          hex: rgbToHex(c.centroid[0], c.centroid[1], c.centroid[2]),
          share: total == 0 ? 0.0 : c.count / total,
        ),
    ];

    final primaryCentroid = merged.first.centroid;
    final primaryLab = rgbToLab(primaryCentroid[0], primaryCentroid[1], primaryCentroid[2]);

    List<int>? secondaryCentroid;
    for (var i = 1; i < merged.length; i++) {
      final c = merged[i].centroid;
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

    return ColorDiagnostics(
      extracted: ExtractedColors(
        primaryHex: primaryHex,
        primaryName: primaryName,
        secondaryHex: secondaryHex,
        secondaryName: secondaryName,
      ),
      clusters: diagnostics,
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

  /// Deterministic k-means in Lab space: farthest-point initialization
  /// (first sample, then repeatedly the sample farthest from all chosen
  /// centroids), followed by [kMeansIterations] assignment/update rounds.
  /// Empty clusters are reseeded with the sample that is farthest from its
  /// assigned centroid. Centroids stay stored as RGB (the caller needs hex);
  /// distances go through the precomputed [sampleLabs] and per-iteration
  /// centroid Lab conversions.
  List<_Cluster> _kMeans(List<List<int>> samples, List<LabColor> sampleLabs) {
    final k = math.min(kMeansClusters, samples.length);

    // Farthest-point initialization (Lab distance for the placement, so a
    // highlight pixel does not seed a "new color" an RGB metric would invent).
    final centroids = <List<int>>[List<int>.from(samples[0])];
    final minDistance = List<double>.filled(
      samples.length,
      double.infinity,
    );
    while (centroids.length < k) {
      final lastLab = rgbToLab(centroids.last[0], centroids.last[1], centroids.last[2]);
      for (var i = 0; i < samples.length; i++) {
        final d = labDistance(sampleLabs[i], lastLab);
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
      final centroidLabs = [
        for (final c in clusters) rgbToLab(c.centroid[0], c.centroid[1], c.centroid[2]),
      ];
      final sums = List.generate(k, (_) => [0.0, 0.0, 0.0]);
      final counts = List<int>.filled(k, 0);
      final assignmentDistance = List<double>.filled(samples.length, double.infinity);

      for (var i = 0; i < samples.length; i++) {
        var bestCluster = 0;
        var bestDistance = double.infinity;
        for (var c = 0; c < k; c++) {
          final d = labDistance(sampleLabs[i], centroidLabs[c]);
          if (d < bestDistance) {
            bestDistance = d;
            bestCluster = c;
          }
        }
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

  /// Folds every cluster whose centroid sits within [mergeMinDeltaE] (Lab)
  /// of a larger cluster into that larger one, weighting the centroid by
  /// pixel count. Deterministic: processes clusters largest-first, so each
  /// fragment always joins the dominant shade of its color.
  List<_Cluster> _mergeNearClusters(List<_Cluster> clusters) {
    final sorted = List<_Cluster>.from(clusters)
      ..sort((a, b) => b.count.compareTo(a.count));
    final merged = <_Cluster>[];
    for (final cluster in sorted) {
      final lab = rgbToLab(cluster.centroid[0], cluster.centroid[1], cluster.centroid[2]);
      _Cluster? target;
      for (final candidate in merged) {
        final candidateLab = rgbToLab(
          candidate.centroid[0],
          candidate.centroid[1],
          candidate.centroid[2],
        );
        if (labDistance(lab, candidateLab) < mergeMinDeltaE) {
          target = candidate;
          break;
        }
      }
      if (target == null) {
        merged.add(_Cluster(List<int>.from(cluster.centroid), cluster.count));
      } else {
        final totalCount = target.count + cluster.count;
        target.centroid = [
          for (var i = 0; i < 3; i++)
            ((target.centroid[i] * target.count + cluster.centroid[i] * cluster.count) /
                    totalCount)
                .round(),
        ];
        target.count = totalCount;
      }
    }
    return merged;
  }
}

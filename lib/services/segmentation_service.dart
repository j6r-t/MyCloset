import 'dart:typed_data';

/// Result of a successful segmentation of one photo.
class SegmentationResult {
  /// RGBA PNG bytes of the cutout (background removed).
  final Uint8List cutoutPng;

  const SegmentationResult(this.cutoutPng);
}

/// Removes the background from an item photo, on device.
///
/// Production implementation: [TFLiteSegmentationService]
/// (docs/backend.md section 3.2).
///
/// Contract for callers (docs/backend.md section 3.3): when [segment] returns
/// null or throws, fall back to the original photo. Keep the item image,
/// store the original path as the cutout path too, and never block saving the
/// item. An implementation must never return a cutout for a
/// photo it could not process.
abstract class SegmentationService {
  /// Returns the cutout, or null when segmentation could not produce a
  /// usable mask (or is simply not available yet).
  Future<SegmentationResult?> segment(Uint8List imageBytes);
}

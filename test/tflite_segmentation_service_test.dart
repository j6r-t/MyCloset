// Host-test contract for the TFLite segmentation service: it must never
// throw through the SegmentationService interface and must return null so
// callers fall back to the original photo (docs/backend.md section 3.3).
// Real inference cannot run on the host (no TFLite native library), so this
// exercises the failure path: undecodable image bytes fail before the
// interpreter is ever touched.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_closet/services/tflite_segmentation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('segment returns null (never throws) for undecodable bytes', () async {
    final service = TFLiteSegmentationService();
    final result = await service.segment(Uint8List.fromList([1, 2, 3]));
    expect(result, isNull);
  });
}

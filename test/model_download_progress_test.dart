import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('ModelDownloadProgress.fromMap', () {
    test('parses canonical native payload', () {
      final p = ModelDownloadProgress.fromMap(const {
        'modelId': 'opennsfw2_coreml',
        'fraction': 0.42,
        'bytesDownloaded': 4200000,
        'totalBytes': 10000000,
      });
      expect(p.modelId, 'opennsfw2_coreml');
      expect(p.fraction, closeTo(0.42, 1e-9));
      expect(p.bytesDownloaded, 4200000);
      expect(p.totalBytes, 10000000);
      expect(p.isComplete, false);
    });

    test('clamps fraction into [0, 1]', () {
      final low = ModelDownloadProgress.fromMap(const {'fraction': -0.5});
      final high = ModelDownloadProgress.fromMap(const {'fraction': 12.0});
      expect(low.fraction, 0.0);
      expect(high.fraction, 1.0);
    });

    test('derives fraction when only bytes are provided', () {
      final p = ModelDownloadProgress.fromMap(const {
        'modelId': 'm',
        'bytesDownloaded': 50,
        'totalBytes': 200,
      });
      expect(p.fraction, closeTo(0.25, 1e-9));
    });

    test('treats fraction >= 1 as complete by default', () {
      final p = ModelDownloadProgress.fromMap(const {
        'modelId': 'm',
        'fraction': 1.0,
      });
      expect(p.isComplete, true);
    });

    test('bytesLabel formats unit transitions and falls back to bytes-only',
        () {
      final partial = ModelDownloadProgress.fromMap(const {
        'modelId': 'm',
        'bytesDownloaded': 5242880, // 5 * 1024 * 1024
        'totalBytes': 20971520, // 20 * 1024 * 1024
      });
      expect(partial.bytesLabel, contains('/'));
      expect(partial.bytesLabel, contains('MB'));

      final unknownTotal = ModelDownloadProgress.fromMap(const {
        'modelId': 'm',
        'bytesDownloaded': 1234,
      });
      expect(unknownTotal.bytesLabel.contains('/'), false);
    });

    test('handles missing modelId by returning empty string', () {
      final p = ModelDownloadProgress.fromMap(const {'fraction': 0.5});
      expect(p.modelId, isEmpty);
      expect(p.fraction, 0.5);
    });
  });
}

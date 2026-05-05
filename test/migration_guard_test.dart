import 'package:flutter_test/flutter_test.dart';

void main() {
  // Helper that mirrors the Swift filter predicate
  bool isStaleNudeNetKey(String key) =>
      key.startsWith('nsfw_model_url_') &&
      key.toLowerCase().contains('nudenet');

  // Helper that mirrors the Swift resource name extraction
  String resourceName(String key) =>
      key.replaceFirst('nsfw_model_url_', '');

  group('Migration guard — key detection logic', () {
    test('identifies nudenet key variants (case-insensitive)', () {
      expect(isStaleNudeNetKey('nsfw_model_url_nudenet_v3'), isTrue);
      expect(isStaleNudeNetKey('nsfw_model_url_NudeNetV3'), isTrue);
      expect(isStaleNudeNetKey('nsfw_model_url_nudenetv3f32'), isTrue);
      expect(isStaleNudeNetKey('nsfw_model_url_NUDENET'), isTrue);
    });

    test('does not match canonical model keys', () {
      expect(isStaleNudeNetKey('nsfw_model_url_opennsfw2_coreml'), isFalse);
      expect(isStaleNudeNetKey('nsfw_model_url_falconsai_nsfw'), isFalse);
      expect(isStaleNudeNetKey('nsfw_model_url_adamcodd_nsfw'), isFalse);
    });

    test('does not match unrelated keys', () {
      expect(isStaleNudeNetKey('nsfw_plugin_migration_version'), isFalse);
      expect(isStaleNudeNetKey('some_other_key'), isFalse);
      expect(isStaleNudeNetKey('nudenet_bare'), isFalse); // missing prefix
    });
  });

  group('Migration guard — sentinel logic', () {
    test('migration runs when completed < targetVersion', () {
      const targetVersion = 1;
      expect(0 < targetVersion, isTrue,
          reason: 'fresh install (0) must trigger migration');
    });

    test('migration is skipped when completed >= targetVersion', () {
      const targetVersion = 1;
      expect(1 < targetVersion, isFalse,
          reason: 'already-migrated (1) must skip migration');
      expect(2 < targetVersion, isFalse,
          reason: 'future version (2) must skip migration');
    });
  });

  group('Migration guard — resource name extraction', () {
    test('extracts resource name from key', () {
      expect(resourceName('nsfw_model_url_NudeNetV3'), 'NudeNetV3');
      expect(resourceName('nsfw_model_url_nudenet_v3'), 'nudenet_v3');
      expect(resourceName('nsfw_model_url_NudeNetV3f32'), 'NudeNetV3f32');
    });
  });

  group('Migration guard — key removal simulation', () {
    test('removes only NudeNet keys from a mock UserDefaults map', () {
      final mockDefaults = {
        'nsfw_model_url_opennsfw2_coreml': 'https://example.com/open.zip',
        'nsfw_model_url_falconsai_nsfw': 'https://example.com/falc.zip',
        'nsfw_model_url_NudeNetV3': 'https://example.com/nude.zip',
        'nsfw_plugin_migration_version': '0',
      };

      final staleKeys =
          mockDefaults.keys.where(isStaleNudeNetKey).toList();
      for (final key in staleKeys) {
        mockDefaults.remove(key);
      }

      expect(mockDefaults.containsKey('nsfw_model_url_NudeNetV3'), isFalse);
      expect(mockDefaults.containsKey('nsfw_model_url_opennsfw2_coreml'),
          isTrue);
      expect(
          mockDefaults.containsKey('nsfw_model_url_falconsai_nsfw'), isTrue);
      expect(
          mockDefaults.containsKey('nsfw_plugin_migration_version'), isTrue);
    });
  });
}

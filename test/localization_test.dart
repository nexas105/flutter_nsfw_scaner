import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  setUp(() {
    NsfwLocalizations.current = const NsfwLocalizationsEn();
  });

  group('NsfwLocalizations.resolve', () {
    test('returns the bundled implementation for each known tag', () {
      expect(NsfwLocalizations.resolve('en').languageCode, 'en');
      expect(NsfwLocalizations.resolve('de').languageCode, 'de');
      expect(NsfwLocalizations.resolve('es').languageCode, 'es');
      expect(NsfwLocalizations.resolve('fr').languageCode, 'fr');
      expect(NsfwLocalizations.resolve('ja').languageCode, 'ja');
    });

    test('ignores region subtag (de_DE → de)', () {
      expect(NsfwLocalizations.resolve('de_DE').languageCode, 'de');
      expect(NsfwLocalizations.resolve('es-MX').languageCode, 'es');
    });

    test('is case-insensitive', () {
      expect(NsfwLocalizations.resolve('DE').languageCode, 'de');
      expect(NsfwLocalizations.resolve('Ja').languageCode, 'ja');
    });

    test('unknown tag falls back to English', () {
      expect(NsfwLocalizations.resolve('xx').languageCode, 'en');
      expect(NsfwLocalizations.resolve('').languageCode, 'en');
    });
  });

  group('PhotoLibraryPermissionStatus.localizedMessage', () {
    test('English default matches the legacy userMessage', () {
      for (final s in PhotoLibraryPermissionStatus.values) {
        expect(
          s.userMessage,
          s.localizedMessage(const NsfwLocalizationsEn()),
        );
      }
    });

    test('German bundle returns translated strings', () {
      const de = NsfwLocalizationsDe();
      expect(
        PhotoLibraryPermissionStatus.authorized.localizedMessage(de),
        contains('Mediathek'),
      );
      expect(
        PhotoLibraryPermissionStatus.denied.localizedMessage(de),
        contains('Einstellungen'),
      );
    });

    test('current-bundle reads honour NsfwLocalizations.current', () {
      NsfwLocalizations.current = const NsfwLocalizationsFr();
      expect(
        PhotoLibraryPermissionStatus.limited.localizedMessage(),
        contains('Accès limité'),
      );
    });
  });

  group('NsfwCategory.localizedName', () {
    test('English default matches the legacy displayName', () {
      for (final c in NsfwCategory.values) {
        expect(
          c.displayName,
          c.localizedName(const NsfwLocalizationsEn()),
        );
      }
    });

    test('Spanish bundle translates explicit nudity', () {
      expect(
        NsfwCategory.explicitNudity
            .localizedName(const NsfwLocalizationsEs()),
        'Desnudez explícita',
      );
    });
  });

  group('ScanResult.localizedConfidenceDescription', () {
    test('matches the threshold ladder in each bundle', () {
      final very = ScanResult.fake(confidence: 0.95);
      final high = ScanResult.fake(confidence: 0.8);
      final mid = ScanResult.fake(confidence: 0.65);
      final low = ScanResult.fake(confidence: 0.45);
      final veryLow = ScanResult.fake(confidence: 0.1);

      const de = NsfwLocalizationsDe();
      expect(very.localizedConfidenceDescription(de), 'Sehr hoch');
      expect(high.localizedConfidenceDescription(de), 'Hoch');
      expect(mid.localizedConfidenceDescription(de), 'Mittel');
      expect(low.localizedConfidenceDescription(de), 'Niedrig');
      expect(veryLow.localizedConfidenceDescription(de), 'Sehr niedrig');
    });

    test('legacy confidenceDescription stays English regardless of current',
        () {
      NsfwLocalizations.current = const NsfwLocalizationsJa();
      final r = ScanResult.fake(confidence: 0.95);
      expect(r.confidenceDescription, 'Very high');
    });
  });

  group('NsfwSafetyProfile.localizedAgeRating', () {
    test('Japanese bundle translates each tier', () {
      const ja = NsfwLocalizationsJa();
      expect(NsfwSafetyProfile.kidSafe.localizedAgeRating(ja), '全年齢');
      expect(NsfwSafetyProfile.teen.localizedAgeRating(ja), 'ティーン');
      expect(NsfwSafetyProfile.adult.localizedAgeRating(ja), '成人');
    });

    test('legacy ageRating stays English', () {
      expect(NsfwSafetyProfile.kidSafe.ageRating, 'all-ages');
      expect(NsfwSafetyProfile.teen.ageRating, 'teen');
      expect(NsfwSafetyProfile.adult.ageRating, 'adult');
    });
  });
}

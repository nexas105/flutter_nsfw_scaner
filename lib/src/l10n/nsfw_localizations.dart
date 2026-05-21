/// Bundle of localized strings used by `nsfw_detect`'s non-widget helpers
/// (`PhotoLibraryPermissionStatus.userMessage`, `NsfwCategory.displayName`,
/// `ScanResult.confidenceDescription`, `NsfwSafetyProfile.ageRating`).
///
/// Why this lives in plain-Dart classes instead of `flutter_localizations`
/// codegen + `.arb` files: the plugin's i18n surface is small (≈20 strings),
/// stable, and not bound to widget contexts — surfacing it through a
/// pluggable interface keeps the runtime footprint zero new deps and lets
/// pure-Dart consumers (e.g. logs, headless tests) get a localized string
/// without booting `MaterialApp.localizationsDelegates`.
///
/// Bundled implementations: English (default), German, Spanish, French,
/// Japanese. Host apps add more languages by implementing
/// [NsfwLocalizations] themselves and wiring the result via
/// [NsfwLocalizations.current] at startup, or by passing the bundle into
/// the call sites that accept one explicitly.
///
/// ```dart
/// // App-wide
/// NsfwLocalizations.current = const NsfwLocalizationsDe();
///
/// // Per-call
/// final msg = PhotoLibraryPermissionStatus.denied
///     .localizedMessage(const NsfwLocalizationsEs());
/// ```
abstract class NsfwLocalizations {
  const NsfwLocalizations();

  /// App-wide default. Reads are synchronous, no async lookup. Default is
  /// English; reassign at startup if you want a different language to be
  /// the global fallback.
  static NsfwLocalizations current = const NsfwLocalizationsEn();

  /// BCP-47 locale tag — `en`, `de`, `es`, `fr`, `ja`, …. Implementations
  /// MUST return a non-empty value so the lookup helpers can pick a
  /// bundle by tag.
  String get languageCode;

  // ── PhotoLibraryPermissionStatus.userMessage
  String get permissionAuthorized;
  String get permissionLimited;
  String get permissionDenied;
  String get permissionRestricted;
  String get permissionNotDetermined;

  // ── NsfwCategory.displayName
  String get categorySafe;
  String get categorySuggestive;
  String get categoryNudity;
  String get categoryExplicitNudity;
  String get categoryUnknown;

  // ── ScanResult.confidenceDescription buckets
  String get confidenceVeryHigh;
  String get confidenceHigh;
  String get confidenceModerate;
  String get confidenceLow;
  String get confidenceVeryLow;

  // ── NsfwSafetyProfile.ageRating
  String get ageRatingAllAges;
  String get ageRatingTeen;
  String get ageRatingAdult;

  /// Resolves [tag] to one of the bundled implementations. Unknown tags
  /// fall back to English. Case-insensitive. The `_REGION` suffix (e.g.
  /// `de_DE`, `es-MX`) is ignored.
  static NsfwLocalizations resolve(String tag) {
    final code = tag.toLowerCase().split(RegExp(r'[-_]')).first;
    switch (code) {
      case 'de':
        return const NsfwLocalizationsDe();
      case 'es':
        return const NsfwLocalizationsEs();
      case 'fr':
        return const NsfwLocalizationsFr();
      case 'ja':
        return const NsfwLocalizationsJa();
      case 'en':
      default:
        return const NsfwLocalizationsEn();
    }
  }
}

/// English (default).
class NsfwLocalizationsEn extends NsfwLocalizations {
  const NsfwLocalizationsEn();

  @override
  String get languageCode => 'en';

  @override
  String get permissionAuthorized => 'Full photo library access';
  @override
  String get permissionLimited =>
      'Limited access — only selected items are scannable';
  @override
  String get permissionDenied =>
      'Access denied — enable photo permission in Settings';
  @override
  String get permissionRestricted => 'Access restricted by device policy';
  @override
  String get permissionNotDetermined =>
      'Permission has not been requested yet';

  @override
  String get categorySafe => 'Safe';
  @override
  String get categorySuggestive => 'Suggestive';
  @override
  String get categoryNudity => 'Nudity';
  @override
  String get categoryExplicitNudity => 'Explicit Nudity';
  @override
  String get categoryUnknown => 'Unknown';

  @override
  String get confidenceVeryHigh => 'Very high';
  @override
  String get confidenceHigh => 'High';
  @override
  String get confidenceModerate => 'Moderate';
  @override
  String get confidenceLow => 'Low';
  @override
  String get confidenceVeryLow => 'Very low';

  @override
  String get ageRatingAllAges => 'all-ages';
  @override
  String get ageRatingTeen => 'teen';
  @override
  String get ageRatingAdult => 'adult';
}

/// German (`de`).
class NsfwLocalizationsDe extends NsfwLocalizations {
  const NsfwLocalizationsDe();

  @override
  String get languageCode => 'de';

  @override
  String get permissionAuthorized => 'Voller Zugriff auf die Mediathek';
  @override
  String get permissionLimited =>
      'Eingeschränkter Zugriff — nur ausgewählte Inhalte sind scannbar';
  @override
  String get permissionDenied =>
      'Zugriff verweigert — Foto-Berechtigung in den Einstellungen aktivieren';
  @override
  String get permissionRestricted =>
      'Zugriff durch Geräterichtlinie eingeschränkt';
  @override
  String get permissionNotDetermined =>
      'Berechtigung wurde noch nicht angefragt';

  @override
  String get categorySafe => 'Unbedenklich';
  @override
  String get categorySuggestive => 'Anzüglich';
  @override
  String get categoryNudity => 'Nacktheit';
  @override
  String get categoryExplicitNudity => 'Explizite Nacktheit';
  @override
  String get categoryUnknown => 'Unbekannt';

  @override
  String get confidenceVeryHigh => 'Sehr hoch';
  @override
  String get confidenceHigh => 'Hoch';
  @override
  String get confidenceModerate => 'Mittel';
  @override
  String get confidenceLow => 'Niedrig';
  @override
  String get confidenceVeryLow => 'Sehr niedrig';

  @override
  String get ageRatingAllAges => 'alle Altersgruppen';
  @override
  String get ageRatingTeen => 'Jugendliche';
  @override
  String get ageRatingAdult => 'Erwachsene';
}

/// Spanish (`es`).
class NsfwLocalizationsEs extends NsfwLocalizations {
  const NsfwLocalizationsEs();

  @override
  String get languageCode => 'es';

  @override
  String get permissionAuthorized =>
      'Acceso completo a la biblioteca de fotos';
  @override
  String get permissionLimited =>
      'Acceso limitado — solo los elementos seleccionados se pueden escanear';
  @override
  String get permissionDenied =>
      'Acceso denegado — activa el permiso de fotos en Ajustes';
  @override
  String get permissionRestricted =>
      'Acceso restringido por la política del dispositivo';
  @override
  String get permissionNotDetermined => 'Aún no se ha solicitado el permiso';

  @override
  String get categorySafe => 'Seguro';
  @override
  String get categorySuggestive => 'Sugerente';
  @override
  String get categoryNudity => 'Desnudez';
  @override
  String get categoryExplicitNudity => 'Desnudez explícita';
  @override
  String get categoryUnknown => 'Desconocido';

  @override
  String get confidenceVeryHigh => 'Muy alta';
  @override
  String get confidenceHigh => 'Alta';
  @override
  String get confidenceModerate => 'Moderada';
  @override
  String get confidenceLow => 'Baja';
  @override
  String get confidenceVeryLow => 'Muy baja';

  @override
  String get ageRatingAllAges => 'todas las edades';
  @override
  String get ageRatingTeen => 'adolescente';
  @override
  String get ageRatingAdult => 'adulto';
}

/// French (`fr`).
class NsfwLocalizationsFr extends NsfwLocalizations {
  const NsfwLocalizationsFr();

  @override
  String get languageCode => 'fr';

  @override
  String get permissionAuthorized =>
      'Accès complet à la bibliothèque de photos';
  @override
  String get permissionLimited =>
      'Accès limité — seuls les éléments sélectionnés sont analysables';
  @override
  String get permissionDenied =>
      'Accès refusé — activez l\'autorisation Photos dans les Réglages';
  @override
  String get permissionRestricted =>
      'Accès restreint par la politique de l\'appareil';
  @override
  String get permissionNotDetermined =>
      'L\'autorisation n\'a pas encore été demandée';

  @override
  String get categorySafe => 'Sûr';
  @override
  String get categorySuggestive => 'Suggestif';
  @override
  String get categoryNudity => 'Nudité';
  @override
  String get categoryExplicitNudity => 'Nudité explicite';
  @override
  String get categoryUnknown => 'Inconnu';

  @override
  String get confidenceVeryHigh => 'Très élevée';
  @override
  String get confidenceHigh => 'Élevée';
  @override
  String get confidenceModerate => 'Modérée';
  @override
  String get confidenceLow => 'Faible';
  @override
  String get confidenceVeryLow => 'Très faible';

  @override
  String get ageRatingAllAges => 'tous publics';
  @override
  String get ageRatingTeen => 'adolescent';
  @override
  String get ageRatingAdult => 'adulte';
}

/// Japanese (`ja`).
class NsfwLocalizationsJa extends NsfwLocalizations {
  const NsfwLocalizationsJa();

  @override
  String get languageCode => 'ja';

  @override
  String get permissionAuthorized => '写真ライブラリへのフルアクセス';
  @override
  String get permissionLimited =>
      '制限付きアクセス — 選択した項目のみスキャンできます';
  @override
  String get permissionDenied => 'アクセスが拒否されました — 設定で写真の権限を有効にしてください';
  @override
  String get permissionRestricted => 'デバイスポリシーによってアクセスが制限されています';
  @override
  String get permissionNotDetermined => '権限はまだ要求されていません';

  @override
  String get categorySafe => '安全';
  @override
  String get categorySuggestive => '挑発的';
  @override
  String get categoryNudity => 'ヌード';
  @override
  String get categoryExplicitNudity => '露骨なヌード';
  @override
  String get categoryUnknown => '不明';

  @override
  String get confidenceVeryHigh => '非常に高い';
  @override
  String get confidenceHigh => '高い';
  @override
  String get confidenceModerate => '中程度';
  @override
  String get confidenceLow => '低い';
  @override
  String get confidenceVeryLow => '非常に低い';

  @override
  String get ageRatingAllAges => '全年齢';
  @override
  String get ageRatingTeen => 'ティーン';
  @override
  String get ageRatingAdult => '成人';
}

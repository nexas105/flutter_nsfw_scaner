import 'package:flutter/foundation.dart';

import '../l10n/nsfw_localizations.dart';

enum NsfwCategory {
  safe,
  suggestive,
  nudity,
  explicitNudity,
  unknown;

  /// English label, kept for source-level compatibility with v2.4.x and
  /// earlier. New code should prefer [localizedName] so user-facing
  /// strings honour [NsfwLocalizations.current].
  String get displayName =>
      localizedName(const NsfwLocalizationsEn());

  /// Localized display name. Defaults to [NsfwLocalizations.current];
  /// pass an explicit [locale] to override per call.
  String localizedName([NsfwLocalizations? locale]) {
    final l = locale ?? NsfwLocalizations.current;
    return switch (this) {
      NsfwCategory.safe => l.categorySafe,
      NsfwCategory.suggestive => l.categorySuggestive,
      NsfwCategory.nudity => l.categoryNudity,
      NsfwCategory.explicitNudity => l.categoryExplicitNudity,
      NsfwCategory.unknown => l.categoryUnknown,
    };
  }

  bool get isNsfw => this == NsfwCategory.nudity || this == NsfwCategory.explicitNudity;
  bool get isSafe => this == NsfwCategory.safe;
}

@immutable
class NsfwLabel {
  final NsfwCategory category;
  final double confidence;

  const NsfwLabel({required this.category, required this.confidence});

  factory NsfwLabel.fromMap(Map<dynamic, dynamic> map) => NsfwLabel(
        category: _categoryFromString(map['category'] as String? ?? 'unknown'),
        confidence: (map['confidence'] as num).toDouble(),
      );

  Map<String, dynamic> toMap() => {
        'category': category.name,
        'confidence': confidence,
      };

  static NsfwCategory _categoryFromString(String s) => switch (s) {
        'safe' => NsfwCategory.safe,
        'suggestive' => NsfwCategory.suggestive,
        'nudity' => NsfwCategory.nudity,
        'explicitNudity' => NsfwCategory.explicitNudity,
        _ => NsfwCategory.unknown,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NsfwLabel && category == other.category && confidence == other.confidence;

  @override
  int get hashCode => Object.hash(category, confidence);

  @override
  String toString() => 'NsfwLabel(${category.displayName}, ${(confidence * 100).toStringAsFixed(1)}%)';
}

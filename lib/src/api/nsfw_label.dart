import 'package:flutter/foundation.dart';

enum NsfwCategory {
  safe,
  suggestive,
  nudity,
  explicitNudity,
  unknown;

  String get displayName => switch (this) {
        NsfwCategory.safe => 'Safe',
        NsfwCategory.suggestive => 'Suggestive',
        NsfwCategory.nudity => 'Nudity',
        NsfwCategory.explicitNudity => 'Explicit Nudity',
        NsfwCategory.unknown => 'Unknown',
      };

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

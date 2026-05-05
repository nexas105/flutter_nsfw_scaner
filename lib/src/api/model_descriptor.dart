import 'package:flutter/foundation.dart';

@immutable
class ModelDescriptor {
  final String id;
  final String displayName;
  final String? description;
  final String? version;
  final Map<String, dynamic> metadata;
  final bool requiresDownload;
  final bool isDownloaded;
  final int downloadSizeBytes;
  final String? downloadUrl;

  const ModelDescriptor({
    required this.id,
    required this.displayName,
    this.description,
    this.version,
    this.metadata = const {},
    this.requiresDownload = false,
    this.isDownloaded = true,
    this.downloadSizeBytes = 0,
    this.downloadUrl,
  });

  /// Whether this model is ready to use (bundled or already downloaded)
  bool get isAvailable => !requiresDownload || isDownloaded;

  /// Human-readable download size
  String get downloadSizeLabel {
    if (downloadSizeBytes <= 0) return '';
    final mb = downloadSizeBytes / (1024 * 1024);
    return '${mb.round()} MB';
  }

  factory ModelDescriptor.fromMap(Map<dynamic, dynamic> map) => ModelDescriptor(
        id: map['id'] as String,
        displayName: map['displayName'] as String,
        description: map['description'] as String?,
        version: map['version'] as String?,
        metadata: (map['metadata'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ?? {},
        requiresDownload: map['requiresDownload'] as bool? ?? false,
        isDownloaded: map['isDownloaded'] as bool? ?? true,
        downloadSizeBytes: map['downloadSizeBytes'] as int? ?? 0,
        downloadUrl: map['downloadUrl'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'displayName': displayName,
        if (description != null) 'description': description,
        if (version != null) 'version': version,
        'metadata': metadata,
        'requiresDownload': requiresDownload,
        'isDownloaded': isDownloaded,
      };

  // Built-in model IDs
  static const String openNsfw2 = 'opennsfw2_coreml';
  static const String falconsai = 'falconsai_nsfw';
  static const String adamcodd = 'adamcodd_nsfw';

  @override
  bool operator ==(Object other) => identical(this, other) || other is ModelDescriptor && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ModelDescriptor($id, $displayName)';
}

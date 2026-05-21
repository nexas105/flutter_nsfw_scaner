import 'package:flutter/foundation.dart';

/// Identifies which inference path consumes a custom-registered model.
enum ModelKind {
  /// Returns per-image NSFW classification probabilities.
  classifier,

  /// Returns per-image body-part bounding-box detections.
  detector;

  String get wireValue => name;

  static ModelKind fromString(String? s) => switch (s) {
        'detector' => ModelKind.detector,
        _ => ModelKind.classifier,
      };
}

/// Runtime registration payload for a custom on-device model.
///
/// Use [NsfwDetector.registerModel] to plug your own .mlmodelc (iOS) or
/// .tflite (Android) artefact into the plugin without forking the package.
/// Registrations live for the process lifetime only — re-register on cold
/// start.
///
/// **Path sandboxing.** [assetPath] is resolved against the host app's
/// sandboxed writable directories (iOS: Application Support / Documents /
/// Caches; Android: `filesDir` / `cacheDir`). Paths that escape the sandbox
/// (`../` traversal, symlinks pointing outside) are rejected by the native
/// side and surface as `INVALID_PATH` on the channel.
///
/// **Why the sandbox.** A flutter plugin can be loaded into apps that
/// already grant full filesystem access (e.g. via SAF / Documents picker);
/// without a sandbox guard a misuse of `registerModel` would let arbitrary
/// model bytes get loaded by the inference engine. Sandboxing means callers
/// must first copy the artefact into the app's own data dir before
/// registering — that copy step is the natural place for the host app to
/// validate provenance.
@immutable
class ModelRegistration {
  /// Stable identifier — must be unique across registrations. Used by
  /// every scan API's `modelId` parameter.
  final String id;

  /// Display label shown by `availableModels()` and any UI that lists
  /// registered models.
  final String displayName;

  /// Filesystem path inside the host app's sandbox. iOS expects a
  /// `.mlmodelc` directory (or `.mlmodel` source which the engine will
  /// compile on first load); Android expects a `.tflite` file.
  final String assetPath;

  /// Input edge length the model expects (square). For classifiers most
  /// CoreML / TFLite NSFW models use 224; ViT variants use 384; detectors
  /// (YOLOv8) typically use 640.
  final int inputSize;

  /// `ModelKind.classifier` (default) or `ModelKind.detector`.
  final ModelKind kind;

  /// Optional download URL — when set, the model is treated as lazy: it's
  /// downloaded on first scan if [assetPath] does not yet exist. Useful
  /// for shipping registrations without preloading bytes.
  final String? downloadUrl;

  /// Optional class-label mapping. Classifier output indices are mapped
  /// to these category names. When omitted the plugin falls back to its
  /// generic 2-class mapping (`["safe", "nudity"]`).
  final List<String>? classLabels;

  /// Optional version string surfaced via `ModelDescriptor.version`.
  final String? version;

  /// Free-form metadata blob passed through to native descriptors. Keys
  /// are JSON-friendly (strings, numbers, bools, lists, maps).
  final Map<String, Object?> metadata;

  const ModelRegistration({
    required this.id,
    required this.displayName,
    required this.assetPath,
    this.inputSize = 224,
    this.kind = ModelKind.classifier,
    this.downloadUrl,
    this.classLabels,
    this.version,
    this.metadata = const {},
  })  : assert(id != ''),
        assert(displayName != ''),
        assert(assetPath != ''),
        assert(inputSize > 0);

  /// Wire-shape map sent across the MethodChannel. The native side rebuilds
  /// a `ModelDescriptorNative` from this and registers it.
  Map<String, Object?> toChannelMap() => {
        'id': id,
        'displayName': displayName,
        'assetPath': assetPath,
        'inputSize': inputSize,
        'kind': kind.wireValue,
        if (downloadUrl != null) 'downloadUrl': downloadUrl,
        if (classLabels != null) 'classLabels': classLabels,
        if (version != null) 'version': version,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  ModelRegistration copyWith({
    String? id,
    String? displayName,
    String? assetPath,
    int? inputSize,
    ModelKind? kind,
    String? downloadUrl,
    List<String>? classLabels,
    String? version,
    Map<String, Object?>? metadata,
  }) =>
      ModelRegistration(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        assetPath: assetPath ?? this.assetPath,
        inputSize: inputSize ?? this.inputSize,
        kind: kind ?? this.kind,
        downloadUrl: downloadUrl ?? this.downloadUrl,
        classLabels: classLabels ?? this.classLabels,
        version: version ?? this.version,
        metadata: metadata ?? this.metadata,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelRegistration &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          displayName == other.displayName &&
          assetPath == other.assetPath &&
          inputSize == other.inputSize &&
          kind == other.kind &&
          downloadUrl == other.downloadUrl &&
          version == other.version;

  @override
  int get hashCode => Object.hash(
        id,
        displayName,
        assetPath,
        inputSize,
        kind,
        downloadUrl,
        version,
      );

  @override
  String toString() =>
      'ModelRegistration($id, $displayName, ${kind.name}@$inputSize)';
}

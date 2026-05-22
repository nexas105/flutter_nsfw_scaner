// Web platform implementation for nsfw_detect.
//
// Registered as the `web` plugin entrypoint in `pubspec.yaml`. Runs entirely
// in the browser — no method channel — using two JS runtimes loaded on demand
// from a CDN:
//
//   * nsfwjs (TensorFlow.js)  → image classification  (`scanImageBytes`)
//   * onnxruntime-web + NudeNet → body-part detection  (`ScanMode.detection`)
//
// Scope (2.6): one-shot APIs only — `scanImageBytes`, `scanFilePath`,
// `pickMedia`. Photo-library scanning, camera scanning and background sweep
// have no browser equivalent and throw `UnimplementedError`. `roi` cropping is
// ignored on web (the platform-interface contract permits this).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import '../api/body_part_detection.dart';
import '../api/camera_configuration.dart';
import '../api/model_descriptor.dart';
import '../api/nsfw_label.dart';
import '../api/scan_configuration.dart';
import 'nsfw_platform_interface.dart';
import 'web/web_category_mapping.dart';
import 'web/web_interop.dart';
import 'web/web_nudenet.dart';

/// Runtime configuration for the web platform. Mutate these statics from the
/// host app **before** the first scan to point at pinned/self-hosted assets
/// instead of the public CDN defaults.
class NsfwWebConfig {
  NsfwWebConfig._();

  /// nsfwjs model-bundle scripts — the browserified model (`model.min.js`)
  /// and its weight shards. Loaded **before** [nsfwjsScriptUrl]; they register
  /// the model as a global that `nsfwjs.load()` then resolves with no
  /// argument. Defaults to the MobileNetV2 model shipped in the nsfwjs npm
  /// package. See nsfwjs' "browserify" docs for the rationale.
  static List<String> nsfwjsModelScripts = [
    'https://cdn.jsdelivr.net/npm/nsfwjs@4.2.1/dist/models/mobilenet_v2/model.min.js',
    'https://cdn.jsdelivr.net/npm/nsfwjs@4.2.1/dist/models/mobilenet_v2/group1-shard1of1.min.js',
  ];

  /// nsfwjs UMD browser bundle. Bundles TensorFlow.js — no separate tfjs
  /// script is needed.
  static String nsfwjsScriptUrl =
      'https://cdn.jsdelivr.net/npm/nsfwjs@4.2.1/dist/browser/nsfwjs.min.js';

  /// onnxruntime-web UMD bundle (NudeNet dependency).
  static String ortScriptUrl =
      'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.20.1/dist/ort.min.js';

  /// URL of the NudeNet v3 `.onnx` graph. **Must be set by the host app** —
  /// there is no universal CDN copy. Detection-mode scans throw a clear
  /// [StateError] until this points at a CORS-reachable model file.
  static String nudeNetModelUrl = '';
}

/// Browser implementation of [NsfwPlatformInterface].
class NsfwDetectWeb extends NsfwPlatformInterface {
  /// Registered by Flutter's generated web plugin registrant.
  static void registerWith(Registrar registrar) {
    NsfwPlatformInterface.instance = NsfwDetectWeb();
  }

  NsfwJsModel? _classifier;
  Future<NsfwJsModel>? _classifierLoading;
  WebNudeNetDetector? _detector;

  // ── Lifecycle / critical ───────────────────────────────────────────────────

  /// Web file picking needs no OS permission, so the one-shot APIs are always
  /// usable. Reported as [PhotoLibraryPermissionStatus.authorized]; note that
  /// photo-library *scanning* still throws — there is no library on web.
  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async =>
      PhotoLibraryPermissionStatus.authorized;

  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async =>
      PhotoLibraryPermissionStatus.authorized;

  @override
  Future<List<ModelDescriptor>> availableModels() async => [
        const ModelDescriptor(
          id: 'nsfwjs',
          displayName: 'nsfwjs (web)',
          description: 'TensorFlow.js NSFW classifier — runs in the browser.',
          metadata: {'kind': 'classifier'},
        ),
        ModelDescriptor(
          id: ModelDescriptor.nudenet,
          displayName: 'NudeNet (web)',
          description: 'onnxruntime-web body-part detector.',
          metadata: const {'kind': 'detector'},
          requiresDownload: true,
          isDownloaded: NsfwWebConfig.nudeNetModelUrl.isNotEmpty,
        ),
      ];

  @override
  Future<void> startScan(ScanConfiguration config) => throw UnimplementedError(
        'startScan: photo-library scanning is not available on web — there is '
        'no device photo library. Use scanImageBytes / scanFilePath / '
        'pickMedia for one-shot scans.',
      );

  @override
  Future<void> cancelScan() async {
    // No library scan can be running on web — safe no-op.
  }

  @override
  Future<void> startCameraScan(CameraConfiguration config) =>
      throw UnimplementedError(
        'startCameraScan is not implemented on web in 2.6.',
      );

  @override
  Future<void> stopCameraScan() async {
    // No camera scan can be running on web — safe no-op.
  }

  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(
    String localIdentifier, {
    String? modelId,
    Map<String, double>? roi,
  }) =>
      throw UnimplementedError(
        'scanSingleAsset: web has no photo-library asset identifiers. Pass '
        'image bytes to scanImageBytes or a blob/object URL to scanFilePath.',
      );

  /// No native event stream on web — library/camera scanning is unsupported,
  /// so the stream is permanently empty.
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      const Stream<Map<dynamic, dynamic>>.empty();

  // ── One-shot scanning ──────────────────────────────────────────────────────

  @override
  Future<void> preloadModel(String modelId) async {
    if (_isDetector(modelId)) {
      await _loadDetector().load();
    } else {
      await _loadClassifier();
    }
  }

  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(
    Uint8List bytes, {
    String? modelId,
    Map<String, double>? roi,
  }) =>
      _scan(
        bytes: bytes,
        modelId: modelId,
        localId: 'web-bytes-${DateTime.now().microsecondsSinceEpoch}',
      );

  /// On web a "file path" is a `blob:`/`http(s):` URL — typically one handed
  /// back by [pickMedia]. The bytes are fetched, then classified like
  /// [scanImageBytes].
  @override
  Future<Map<dynamic, dynamic>> scanFilePath(
    String filePath, {
    String? modelId,
    Map<String, double>? roi,
  }) async {
    final response = await web.window.fetch(filePath.toJS).toDart;
    if (!response.ok) {
      throw StateError(
        'nsfw_detect: scanFilePath could not fetch $filePath '
        '(HTTP ${response.status}).',
      );
    }
    final buffer = await response.arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();
    return _scan(bytes: bytes, modelId: modelId, localId: filePath);
  }

  @override
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = _acceptFor(type)
      ..multiple = multiple;

    final completer = Completer<web.FileList?>();
    input.onchange = (web.Event _) {
      if (!completer.isCompleted) completer.complete(input.files);
    }.toJS;
    input.click();

    final files = await completer.future;
    if (files == null) return const [];

    final out = <Map<dynamic, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      if (maxItems != null && out.length >= maxItems) break;
      final file = files.item(i);
      if (file == null) continue;
      final url = web.URL.createObjectURL(file);
      out.add({
        'localId': url,
        'filePath': url,
        'mediaType': file.type.startsWith('video/') ? 'video' : 'image',
      });
    }
    return out;
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  bool _isDetector(String? modelId) {
    if (modelId == null) return false;
    final id = modelId.toLowerCase();
    return id == ModelDescriptor.nudenet || id.contains('nudenet');
  }

  /// Shared scan body for [scanImageBytes] / [scanFilePath]: decode the image,
  /// route to the classifier or the detector, and build a `ScanResult`-shaped
  /// wire map.
  Future<Map<dynamic, dynamic>> _scan({
    required Uint8List bytes,
    required String? modelId,
    required String localId,
  }) async {
    final bitmap = await decodeImage(bytes);

    if (_isDetector(modelId)) {
      final raster = rasterize(bitmap, nudeNetInputSize);
      final detections = await _loadDetector().detect(raster);
      return _resultMap(
        localId: localId,
        labels: _labelsFromDetections(detections),
        detections: detections,
      );
    }

    final model = await _loadClassifier();
    final predictions = await model.classify(bitmap).toDart;
    final rawProbs = <String, double>{};
    for (final p in predictions.toDart) {
      rawProbs[p.className] = p.probability;
    }
    return _resultMap(
      localId: localId,
      labels: aggregateNsfwjsPredictions(rawProbs),
    );
  }

  Future<NsfwJsModel> _loadClassifier() {
    final cached = _classifier;
    if (cached != null) return Future.value(cached);
    return _classifierLoading ??= () async {
      // Model-bundle scripts first — they register the browserified model as
      // a global; the nsfwjs bundle (which embeds TensorFlow.js) goes last.
      for (final url in NsfwWebConfig.nsfwjsModelScripts) {
        await ensureScript(url);
      }
      await ensureScript(NsfwWebConfig.nsfwjsScriptUrl);
      final namespace = nsfwjsGlobal;
      if (namespace == null) {
        throw StateError(
          'nsfw_detect: nsfwjs loaded but the global `nsfwjs` is missing.',
        );
      }
      final model = await namespace.load().toDart;
      _classifier = model;
      _classifierLoading = null;
      return model;
    }();
  }

  WebNudeNetDetector _loadDetector() {
    if (NsfwWebConfig.nudeNetModelUrl.isEmpty) {
      throw StateError(
        'nsfw_detect: detection-mode scanning on web needs a NudeNet model. '
        'Set NsfwWebConfig.nudeNetModelUrl to a CORS-reachable .onnx URL.',
      );
    }
    return _detector ??= WebNudeNetDetector(
      modelUrl: NsfwWebConfig.nudeNetModelUrl,
      ortScriptUrl: NsfwWebConfig.ortScriptUrl,
    );
  }

  /// Collapses a detection list into classifier-style [NsfwLabel]s so a pure
  /// detection scan still yields a meaningful `topCategory` / `isNsfw`. Each
  /// category keeps the highest-confidence box that aggregated into it.
  List<NsfwLabel> _labelsFromDetections(List<RawDetection> detections) {
    final byCategory = <NsfwCategory, double>{};
    for (final det in detections) {
      final label = det['label'] as String? ?? '';
      final confidence = (det['confidence'] as num?)?.toDouble() ?? 0.0;
      final category = BodyPartDetection.aggregateCategoryFromLabel(label);
      if (confidence > (byCategory[category] ?? 0.0)) {
        byCategory[category] = confidence;
      }
    }
    final labels = byCategory.entries
        .map((e) => NsfwLabel(category: e.key, confidence: e.value))
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return labels;
  }

  Map<String, Object?> _resultMap({
    required String localId,
    required List<NsfwLabel> labels,
    List<RawDetection>? detections,
  }) =>
      {
        'localId': localId,
        'mediaType': 'image',
        'status': 'completed',
        'labels': labels
            .map((l) => {
                  'category': l.category.name,
                  'confidence': l.confidence,
                })
            .toList(),
        if (detections != null && detections.isNotEmpty)
          'detections': detections,
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
      };

  String _acceptFor(String pickerType) {
    switch (pickerType) {
      case 'image':
        return 'image/*';
      case 'video':
        return 'video/*';
      default:
        return 'image/*,video/*';
    }
  }
}

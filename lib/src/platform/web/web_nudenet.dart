// NudeNet body-part detector for the web platform.
//
// Runs the NudeNet v3 YOLO ONNX graph through onnxruntime-web and decodes the
// raw output into the plugin's `BodyPartDetection` wire shape.
//
// ⚠️  BROWSER-VERIFY: the constants below (model URL, input/output tensor
// names, input size, class order, output layout) match NudeNet v3's published
// `320n.onnx`. If you swap in a different NudeNet build, re-check them against
// `session.inputNames` / `session.outputNames` and the model card — the YOLO
// decode is generic but the I/O names and class order are not.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'web_interop.dart';

/// NudeNet v3's 18 detection classes, in the model's native output order.
/// Index `i` in the class-score block of the YOLO output maps to
/// `nudeNetClasses[i]`. These raw labels feed
/// `BodyPartDetection.aggregateCategoryFromLabel` on the Dart side.
const List<String> nudeNetClasses = [
  'FEMALE_GENITALIA_COVERED', // 0
  'FACE_FEMALE', // 1
  'BUTTOCKS_EXPOSED', // 2
  'FEMALE_BREAST_EXPOSED', // 3
  'FEMALE_GENITALIA_EXPOSED', // 4
  'MALE_BREAST_EXPOSED', // 5
  'ANUS_EXPOSED', // 6
  'FEET_EXPOSED', // 7
  'BELLY_COVERED', // 8
  'FEET_COVERED', // 9
  'ARMPITS_COVERED', // 10
  'ARMPITS_EXPOSED', // 11
  'FACE_MALE', // 12
  'BELLY_EXPOSED', // 13
  'MALE_GENITALIA_EXPOSED', // 14
  'ANUS_COVERED', // 15
  'FEMALE_BREAST_COVERED', // 16
  'BUTTOCKS_COVERED', // 17
];

/// Square input resolution of the NudeNet 320n graph.
const int nudeNetInputSize = 320;

/// A decoded detection in normalised `[0, 1]` xywh coordinates — the exact
/// shape `BodyPartDetection.fromMap` consumes (`label`, `confidence`, `box`).
typedef RawDetection = Map<String, Object?>;

/// Loads the NudeNet ONNX graph and runs detection on rasterized images.
///
/// One instance is created per [modelUrl]; [load] is idempotent and caches the
/// session for the lifetime of the page.
class WebNudeNetDetector {
  WebNudeNetDetector({
    required this.modelUrl,
    required this.ortScriptUrl,
    this.scoreThreshold = 0.20,
    this.iouThreshold = 0.45,
  });

  /// URL of the NudeNet `.onnx` file.
  final String modelUrl;

  /// URL of the onnxruntime-web UMD bundle.
  final String ortScriptUrl;

  /// Minimum class confidence for a box to survive.
  final double scoreThreshold;

  /// IoU above which the lower-scoring box is suppressed during NMS.
  final double iouThreshold;

  OrtSession? _session;
  Future<OrtSession>? _loading;

  /// Loads the ort runtime + model graph. Safe to call repeatedly.
  Future<OrtSession> load() {
    final cached = _session;
    if (cached != null) return Future.value(cached);
    return _loading ??= _loadImpl();
  }

  Future<OrtSession> _loadImpl() async {
    await ensureScript(ortScriptUrl);
    if (ortGlobal == null) {
      throw StateError(
        'nsfw_detect: onnxruntime-web loaded but the global `ort` is missing',
      );
    }
    final session =
        await OrtInferenceSession.create(modelUrl.toJS).toDart;
    _session = session;
    _loading = null;
    return session;
  }

  /// Runs detection on an already-decoded image and returns the surviving
  /// boxes as `BodyPartDetection`-shaped maps.
  Future<List<RawDetection>> detect(RasterizedImage image) async {
    final session = await load();

    final nchw = rgbaToNchwFloat32(image);
    final dims = <JSNumber>[
      1.toJS,
      3.toJS,
      nudeNetInputSize.toJS,
      nudeNetInputSize.toJS,
    ].toJS;
    final inputTensor = OrtTensor('float32', nchw.toJS, dims);

    final inputName = (session.inputNames.toDart.first).toDart;
    final feeds = JSObject();
    feeds.setProperty(inputName.toJS, inputTensor);

    final results = await session.run(feeds).toDart;
    final outputName = (session.outputNames.toDart.first).toDart;
    final output = results.getProperty<OrtTensor>(outputName.toJS);

    final data = (output.data as JSFloat32Array).toDart;
    final shape =
        output.dims.toDart.map((d) => d.toDartInt).toList(growable: false);
    return _decodeYolo(data, shape);
  }

  /// Decodes a raw YOLOv8 output tensor into NMS-filtered detections.
  ///
  /// Accepts both common layouts: channels-first `[1, 4+C, anchors]` (NudeNet
  /// 320n's native shape) and anchors-first `[1, anchors, 4+C]`. Boxes arrive
  /// as centre `cx, cy, w, h` in input-pixel space and leave as top-left
  /// `x, y, w, h` normalised to `[0, 1]`.
  List<RawDetection> _decodeYolo(Float32List data, List<int> shape) {
    if (shape.length != 3) return const [];
    final d1 = shape[1];
    final d2 = shape[2];

    // The channel block is 4 box coords + one score per class; it is far
    // smaller than the anchor count, so the smaller dim is the channel dim.
    final channelsFirst = d1 <= d2;
    final channels = channelsFirst ? d1 : d2;
    final anchors = channelsFirst ? d2 : d1;
    final numClasses = channels - 4;
    if (numClasses <= 0) return const [];

    double at(int channel, int anchor) => channelsFirst
        ? data[channel * anchors + anchor]
        : data[anchor * channels + channel];

    const inputSize = nudeNetInputSize;
    final candidates = <_Box>[];
    for (var a = 0; a < anchors; a++) {
      var bestClass = 0;
      var bestScore = 0.0;
      for (var c = 0; c < numClasses; c++) {
        final score = at(4 + c, a);
        if (score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      if (bestScore < scoreThreshold) continue;

      final cx = at(0, a);
      final cy = at(1, a);
      final w = at(2, a);
      final h = at(3, a);
      candidates.add(_Box(
        x: (cx - w / 2) / inputSize,
        y: (cy - h / 2) / inputSize,
        w: w / inputSize,
        h: h / inputSize,
        score: bestScore,
        classIndex: bestClass,
      ));
    }

    final kept = _nms(candidates);
    return kept.map((b) {
      final label = b.classIndex < nudeNetClasses.length
          ? nudeNetClasses[b.classIndex]
          : 'UNKNOWN';
      return <String, Object?>{
        'label': label,
        'confidence': b.score,
        'box': {
          'x': b.x.clamp(0.0, 1.0),
          'y': b.y.clamp(0.0, 1.0),
          'width': b.w.clamp(0.0, 1.0),
          'height': b.h.clamp(0.0, 1.0),
        },
      };
    }).toList(growable: false);
  }

  /// Greedy class-agnostic non-maximum suppression.
  List<_Box> _nms(List<_Box> boxes) {
    boxes.sort((a, b) => b.score.compareTo(a.score));
    final kept = <_Box>[];
    final suppressed = List<bool>.filled(boxes.length, false);
    for (var i = 0; i < boxes.length; i++) {
      if (suppressed[i]) continue;
      kept.add(boxes[i]);
      for (var j = i + 1; j < boxes.length; j++) {
        if (suppressed[j]) continue;
        if (_iou(boxes[i], boxes[j]) > iouThreshold) suppressed[j] = true;
      }
    }
    return kept;
  }

  double _iou(_Box a, _Box b) {
    final ix1 = a.x > b.x ? a.x : b.x;
    final iy1 = a.y > b.y ? a.y : b.y;
    final ix2 =
        (a.x + a.w) < (b.x + b.w) ? (a.x + a.w) : (b.x + b.w);
    final iy2 =
        (a.y + a.h) < (b.y + b.h) ? (a.y + a.h) : (b.y + b.h);
    final iw = ix2 - ix1;
    final ih = iy2 - iy1;
    if (iw <= 0 || ih <= 0) return 0.0;
    final intersection = iw * ih;
    final union = a.w * a.h + b.w * b.h - intersection;
    return union <= 0 ? 0.0 : intersection / union;
  }
}

/// Internal mutable box used during decode + NMS.
class _Box {
  _Box({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.score,
    required this.classIndex,
  });

  final double x;
  final double y;
  final double w;
  final double h;
  final double score;
  final int classIndex;
}

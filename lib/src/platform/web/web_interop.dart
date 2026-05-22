// Low-level browser interop for the web platform implementation.
//
// Holds the `dart:js_interop` bindings for the two JS runtimes the web
// platform leans on (nsfwjs for classification, onnxruntime-web for NudeNet
// detection), a small CDN `<script>` loader, and image-decode helpers.
//
// This file is compiled for the web target only — it is reachable solely
// through `nsfw_web.dart`, which `pubspec.yaml` registers as the web plugin
// entrypoint. `dart:js_interop` and `package:web` analyze fine everywhere, so
// `flutter analyze` on a mobile checkout still type-checks it.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// ── CDN script loader ────────────────────────────────────────────────────────

final Map<String, Future<void>> _scriptCache = {};

/// Injects `<script src=url>` into `<head>` once and resolves when it loads.
/// Concurrent and repeat calls for the same [url] share a single future, so a
/// runtime is fetched at most once per page.
Future<void> ensureScript(String url) {
  return _scriptCache.putIfAbsent(url, () {
    final completer = Completer<void>();
    final script = web.HTMLScriptElement()
      ..src = url
      ..async = true;
    script.onload = (web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }.toJS;
    script.onerror = (web.Event _) {
      _scriptCache.remove(url); // allow a later retry
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('nsfw_detect: failed to load script $url'),
        );
      }
    }.toJS;
    web.document.head!.appendChild(script);
    return completer.future;
  });
}

// ── nsfwjs bindings ──────────────────────────────────────────────────────────

@JS('nsfwjs')
external NsfwJsNamespace? get nsfwjsGlobal;

/// The global `nsfwjs` UMD object.
extension type NsfwJsNamespace._(JSObject _) implements JSObject {
  /// `nsfwjs.load(pathOrModel?, options?)` → a ready classifier model.
  external JSPromise<NsfwJsModel> load([JSAny? pathOrModel, JSObject? options]);
}

/// A loaded nsfwjs classifier.
extension type NsfwJsModel._(JSObject _) implements JSObject {
  /// `model.classify(image, topk?)` → per-class predictions.
  external JSPromise<JSArray<NsfwJsPrediction>> classify(
    JSObject image, [
    JSNumber topk,
  ]);
}

/// One `{className, probability}` row from `model.classify()`.
extension type NsfwJsPrediction._(JSObject _) implements JSObject {
  external String get className;
  external double get probability;
}

// ── onnxruntime-web bindings ─────────────────────────────────────────────────

@JS('ort')
external JSObject? get ortGlobal;

/// `ort.InferenceSession` — static `create` builds a session from a URL.
@JS('ort.InferenceSession')
extension type OrtInferenceSession._(JSObject _) implements JSObject {
  external static JSPromise<OrtSession> create(
    JSAny path, [
    JSObject? options,
  ]);
}

/// A live ONNX inference session.
extension type OrtSession._(JSObject _) implements JSObject {
  external JSPromise<JSObject> run(JSObject feeds);
  external JSArray<JSString> get inputNames;
  external JSArray<JSString> get outputNames;
}

/// `ort.Tensor` — a typed input/output buffer with a shape.
@JS('ort.Tensor')
extension type OrtTensor._(JSObject _) implements JSObject {
  external factory OrtTensor(String type, JSAny data, JSArray<JSNumber> dims);
  external JSAny get data;
  external JSArray<JSNumber> get dims;
}

// ── image decode / preprocessing helpers ─────────────────────────────────────

/// Decodes encoded image [bytes] (JPEG/PNG/WebP/…) into an [web.ImageBitmap]
/// the browser can draw onto a canvas. [mimeType] is a hint for the `Blob`;
/// `createImageBitmap` sniffs the actual format regardless.
Future<web.ImageBitmap> decodeImage(
  Uint8List bytes, {
  String mimeType = 'image/jpeg',
}) async {
  final parts = <JSAny>[bytes.toJS].toJS;
  final blob = web.Blob(parts, web.BlobPropertyBag(type: mimeType));
  return web.window.createImageBitmap(blob).toDart;
}

/// Result of rasterizing an [web.ImageBitmap] onto a fixed-size RGBA canvas.
class RasterizedImage {
  RasterizedImage({
    required this.rgba,
    required this.size,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  /// Row-major RGBA bytes, length `size * size * 4`.
  final Uint8ClampedList rgba;

  /// Side length of the square canvas the bitmap was scaled into.
  final int size;

  /// Original bitmap dimensions, before the square rescale.
  final int sourceWidth;
  final int sourceHeight;
}

/// Draws [bitmap] into a `size`×`size` RGBA canvas (stretched, no
/// letterboxing) and returns the raw pixels. Used to build model input
/// tensors. Stretching matches what nsfwjs / NudeNet preprocessing expect.
RasterizedImage rasterize(web.ImageBitmap bitmap, int size) {
  final canvas = web.HTMLCanvasElement()
    ..width = size
    ..height = size;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(bitmap, 0, 0, size.toDouble(), size.toDouble());
  final imageData = ctx.getImageData(0, 0, size, size);
  return RasterizedImage(
    rgba: imageData.data.toDart,
    size: size,
    sourceWidth: bitmap.width,
    sourceHeight: bitmap.height,
  );
}

/// Converts a [RasterizedImage] into a planar NCHW `Float32List`
/// (`[1, 3, size, size]`), normalising each channel to `[0, 1]`. This is the
/// input layout expected by the NudeNet YOLO ONNX graph.
Float32List rgbaToNchwFloat32(RasterizedImage image) {
  final size = image.size;
  final plane = size * size;
  final out = Float32List(3 * plane);
  final rgba = image.rgba;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final px = (y * size + x) * 4;
      final idx = y * size + x;
      out[idx] = rgba[px] / 255.0; // R plane
      out[plane + idx] = rgba[px + 1] / 255.0; // G plane
      out[2 * plane + idx] = rgba[px + 2] / 255.0; // B plane
    }
  }
  return out;
}

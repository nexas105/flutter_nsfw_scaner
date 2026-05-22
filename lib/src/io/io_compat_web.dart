/// Web implementation of the [io_compat] shim. The browser has no general
/// filesystem, so a "path" here is a `blob:` / `http(s):` URL and file reads
/// go through `fetch`.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:web/web.dart' as web;

/// Web stand-in for `dart:io`'s `File`. [path] is a URL; [readAsBytes]
/// fetches it. There is no write/sync surface — the browser cannot expose an
/// arbitrary filesystem.
class File {
  File(this.path);

  /// A `blob:` / `http(s):` URL identifying the bytes.
  final String path;

  /// Fetches [path] and returns its bytes.
  Future<Uint8List> readAsBytes() async {
    final response = await web.window.fetch(path.toJS).toDart;
    if (!response.ok) {
      throw StateError(
        'nsfw_detect: could not read $path (HTTP ${response.status}).',
      );
    }
    final buffer = await response.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }
}

/// Web stand-in for `dart:io`'s `HttpException`, thrown by [httpGetBytes] on a
/// non-2xx response so `scanUrl` surfaces failures uniformly across platforms.
class HttpException implements Exception {
  HttpException(this.message, {this.uri});

  final String message;
  final Uri? uri;

  @override
  String toString() =>
      'HttpException: $message${uri == null ? '' : ' (uri: $uri)'}';
}

/// Fetches [url] via the browser `fetch` API. Throws [HttpException] on a
/// non-2xx status and [StateError] when the body exceeds [maxBytes].
///
/// Unlike the native path the browser buffers the whole response before the
/// size can be checked, so [maxBytes] is enforced after the download rather
/// than aborting mid-stream.
Future<Uint8List> httpGetBytes(
  Uri url, {
  Map<String, String>? headers,
  required Duration timeout,
  required int maxBytes,
}) async {
  final init = web.RequestInit();
  if (headers != null && headers.isNotEmpty) {
    final jsHeaders = web.Headers();
    headers.forEach((key, value) => jsHeaders.append(key, value));
    init.headers = jsHeaders;
  }
  final response = await web.window
      .fetch(url.toString().toJS, init)
      .toDart
      .timeout(timeout);
  if (!response.ok) {
    throw HttpException('HTTP ${response.status} fetching $url', uri: url);
  }
  final buffer = await response.arrayBuffer().toDart;
  final bytes = buffer.toDart.asUint8List();
  if (bytes.length > maxBytes) {
    throw StateError(
      'Remote payload exceeds $maxBytes bytes for $url — aborting',
    );
  }
  return bytes;
}

/// `NsfwResultRedactor.file` is not supported on web — the browser has no
/// file paths to back an `ImageProvider`. Pass an `Image.network` child to the
/// default `NsfwResultRedactor` constructor instead.
ImageProvider fileImageProvider(String path) => throw UnsupportedError(
      'NsfwResultRedactor.file / file-backed images are not available on web. '
      'Use the default NsfwResultRedactor constructor with an Image.network '
      'child (e.g. a blob URL).',
    );

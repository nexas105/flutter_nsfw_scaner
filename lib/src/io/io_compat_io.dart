/// Native (`dart:io`) implementation of the [io_compat] shim. Used on every
/// platform except the web.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

export 'dart:io' show File, HttpException;

/// Fetches [url] and returns the response body. Throws [io.HttpException] on a
/// non-2xx status, [StateError] when the body exceeds [maxBytes], and
/// `TimeoutException` when [timeout] elapses.
Future<Uint8List> httpGetBytes(
  Uri url, {
  Map<String, String>? headers,
  required Duration timeout,
  required int maxBytes,
}) async {
  final client = io.HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(url).timeout(timeout);
    headers?.forEach((key, value) => request.headers.add(key, value));
    final response = await request.close().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw io.HttpException(
        'HTTP ${response.statusCode} fetching $url',
        uri: url,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw StateError(
          'Remote payload exceeds $maxBytes bytes for $url — aborting',
        );
      }
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// An [ImageProvider] backed by an on-disk file path.
ImageProvider fileImageProvider(String path) => FileImage(io.File(path));

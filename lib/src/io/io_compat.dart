/// Cross-platform compatibility shim for the handful of `dart:io` features
/// the plugin needs (a `File` handle, HTTP byte fetch, file-backed
/// `ImageProvider`).
///
/// `dart:io` is unavailable on the web, so importing it anywhere reachable
/// from the public barrel (`nsfw_detect.dart`) would break web compilation
/// outright. Code imports this file instead; the conditional export below
/// resolves to the native implementation off the web and to a browser
/// implementation (`fetch` / object URLs) on it.
library;

export 'io_compat_io.dart' if (dart.library.js_interop) 'io_compat_web.dart';

// Compatibility shim — re-exports the canonical platform interface.
//
// The implementation moved to `src/platform/nsfw_platform_interface.dart` in
// v2.2. This file exists so consumers still importing the legacy path against
// 2.x continue to compile. Prefer the new path going forward.
@Deprecated('Import package:nsfw_detect/nsfw_detect.dart instead. '
    'This re-export will be removed in 3.0.')
library;

export 'src/platform/nsfw_platform_interface.dart';

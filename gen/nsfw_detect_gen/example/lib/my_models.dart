import 'package:nsfw_detect/nsfw_detect.dart';

part 'my_models.g.dart';

/// Minimal example: annotate a couple of model ids and let the
/// `nsfw_detect_gen` builder emit a typed registry.
///
/// Run `dart run build_runner build --delete-conflicting-outputs` from
/// `gen/nsfw_detect_gen/example/` to regenerate `my_models.g.dart`.
class MyModels {
  const MyModels();

  @NsfwModel(
    id: 'opennsfw2_coreml',
    defaultThreshold: 0.6,
    displayName: 'OpenNSFW 2',
    tags: {'classification', 'open-source'},
  )
  static const String openNsfw2 = 'opennsfw2_coreml';

  @NsfwModel(
    id: 'nudenet',
    defaultThreshold: 0.7,
    defaultMode: ScanMode.detection,
    displayName: 'NudeNet',
    tags: {'detection', 'permissive-license'},
  )
  static const String nudeNet = 'nudenet';
}

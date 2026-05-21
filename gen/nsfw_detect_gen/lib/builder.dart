import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/nsfw_model_generator.dart';

/// Builder entry point referenced from `build.yaml`. Wires the
/// [NsfwModelGenerator] into `source_gen`'s combining builder so each input
/// `.dart` file emits a sibling `.g.dart` with `part of` glue.
Builder nsfwModelBuilder(BuilderOptions options) =>
    SharedPartBuilder([NsfwModelGenerator()], 'nsfw_model');

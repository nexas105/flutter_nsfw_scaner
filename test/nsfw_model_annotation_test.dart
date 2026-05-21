// Unit tests for the [NsfwModel] annotation (#64).
//
// The annotation itself has no runtime behaviour beyond holding metadata
// for the `nsfw_detect_gen` builder — these tests pin the documented
// defaults and the immutability contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  test('constructs with required id and documented defaults', () {
    const m = NsfwModel(id: 'foo');
    expect(m.id, 'foo');
    expect(m.defaultThreshold, 0.7);
    expect(m.defaultMode, ScanMode.classification);
    expect(m.displayName, isNull);
    expect(m.tags, isEmpty);
  });

  test('honours all explicitly-set fields', () {
    const m = NsfwModel(
      id: 'opennsfw2_coreml',
      defaultThreshold: 0.62,
      defaultMode: ScanMode.detection,
      displayName: 'OpenNSFW 2',
      tags: {'classification', 'open-source'},
    );
    expect(m.id, 'opennsfw2_coreml');
    expect(m.defaultThreshold, 0.62);
    expect(m.defaultMode, ScanMode.detection);
    expect(m.displayName, 'OpenNSFW 2');
    expect(m.tags, {'classification', 'open-source'});
  });

  test('is `const` constructible — usable in annotation position', () {
    // The annotation must be a `const` expression so it can decorate a
    // `static const String` field. If this compiles, the contract holds.
    const annotation = NsfwModel(id: 'compile-time');
    expect(annotation, isA<NsfwModel>());
  });

  test('tags set is effectively immutable on the annotation', () {
    const m = NsfwModel(
      id: 'fixed',
      tags: {'classification'},
    );
    // The annotation is annotated `@immutable`; mutating a const literal
    // throws. We verify by attempting to mutate and expecting a throw.
    expect(() => m.tags.add('mutated'), throwsUnsupportedError);
    expect(m.tags, {'classification'});
  });

  test('identical const instances share identity', () {
    const a = NsfwModel(id: 'same');
    const b = NsfwModel(id: 'same');
    expect(identical(a, b), isTrue,
        reason: 'const canonicalisation should fold identical literals');
  });
}

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

/// Generator for `@NsfwModel` annotations.
///
/// Triggers on any `@NsfwModel(...)` annotation attached to either:
///
/// * a `static const String` field inside a class, or
/// * the class itself (the class-level annotation flag is recorded so the
///   generator can emit a `_$Registry` per annotated class even when the
///   author hasn't tagged any fields).
///
/// For each annotated class the generator emits:
///
/// * `class _$<ClassName>Registry` with typed `String get fieldName` getters,
/// * a `Map<String, NsfwModel> models` literal keyed by model id,
/// * a `Future<void> registerAll(NsfwDetector detector)` helper that calls
///   `detector.models.ensureReady(id)` for every annotated id.
class NsfwModelGenerator extends Generator {
  static const _annotationName = 'NsfwModel';

  @override
  Future<String> generate(LibraryReader library, BuildStep buildStep) async {
    final buffer = StringBuffer();
    var emittedAny = false;

    for (final classElement in library.classes) {
      final entries = _collectEntries(classElement);
      if (entries.isEmpty) continue;
      emittedAny = true;
      _emitRegistry(buffer, classElement.name, entries);
    }

    if (!emittedAny) return '';
    return buffer.toString();
  }

  List<_ModelEntry> _collectEntries(ClassElement classElement) {
    final entries = <_ModelEntry>[];
    for (final field in classElement.fields) {
      if (!field.isStatic || !field.isConst) continue;
      final annotation = _readAnnotation(field);
      if (annotation == null) continue;
      entries.add(_ModelEntry(
        fieldName: field.name,
        annotation: annotation,
      ));
    }
    // Class-level annotation: synthesise a single entry using the class name
    // as the field name when no fields were annotated.
    if (entries.isEmpty) {
      final classAnnotation = _readAnnotation(classElement);
      if (classAnnotation != null) {
        entries.add(_ModelEntry(
          fieldName: _lowerFirst(classElement.name),
          annotation: classAnnotation,
        ));
      }
    }
    return entries;
  }

  _ParsedAnnotation? _readAnnotation(Element element) {
    for (final metadata in element.metadata) {
      final value = metadata.computeConstantValue();
      if (value == null) continue;
      final type = value.type;
      if (type == null) continue;
      if (type.getDisplayString(withNullability: false) != _annotationName) {
        continue;
      }

      final id = value.getField('id')?.toStringValue();
      if (id == null) continue;

      final defaultThreshold =
          value.getField('defaultThreshold')?.toDoubleValue() ?? 0.7;
      final defaultModeRaw = value.getField('defaultMode');
      final defaultModeName = defaultModeRaw?.getField('_name')?.toStringValue() ??
          defaultModeRaw?.variable?.name ??
          'classification';
      final displayName =
          value.getField('displayName')?.toStringValue();
      final tagsRaw = value.getField('tags')?.toSetValue();
      final tags = <String>{
        if (tagsRaw != null)
          for (final t in tagsRaw)
            if (t.toStringValue() != null) t.toStringValue()!,
      };

      return _ParsedAnnotation(
        id: id,
        defaultThreshold: defaultThreshold,
        defaultMode: defaultModeName,
        displayName: displayName,
        tags: tags,
      );
    }
    return null;
  }

  void _emitRegistry(
    StringBuffer buffer,
    String className,
    List<_ModelEntry> entries,
  ) {
    final registryName = '_\$${className}Registry';
    buffer
      ..writeln()
      ..writeln('/// Generated registry for `$className`. Do not edit by hand.')
      ..writeln('class $registryName {')
      ..writeln('  const $registryName();')
      ..writeln();

    // Typed id getters.
    for (final e in entries) {
      buffer
        ..writeln(
            "  /// Stable id for `$className.${e.fieldName}` (threshold ${e.annotation.defaultThreshold}).")
        ..writeln(
            "  String get ${e.fieldName} => '${_escape(e.annotation.id)}';")
        ..writeln();
    }

    // Threshold getters.
    for (final e in entries) {
      buffer
        ..writeln(
            "  /// Suggested confidence threshold for `${e.fieldName}`.")
        ..writeln(
            "  double get ${e.fieldName}Threshold => ${e.annotation.defaultThreshold};")
        ..writeln();
    }

    // models map.
    buffer
      ..writeln('  /// All annotated models keyed by id.')
      ..writeln('  Map<String, NsfwModel> get models => const {');
    for (final e in entries) {
      final tagsLiteral = e.annotation.tags.isEmpty
          ? '<String>{}'
          : '{${e.annotation.tags.map((t) => "'${_escape(t)}'").join(', ')}}';
      buffer
        ..writeln("    '${_escape(e.annotation.id)}': NsfwModel(")
        ..writeln("      id: '${_escape(e.annotation.id)}',")
        ..writeln(
            "      defaultThreshold: ${e.annotation.defaultThreshold},")
        ..writeln(
            "      defaultMode: ScanMode.${e.annotation.defaultMode},");
      if (e.annotation.displayName != null) {
        buffer.writeln(
            "      displayName: '${_escape(e.annotation.displayName!)}',");
      }
      buffer
        ..writeln("      tags: $tagsLiteral,")
        ..writeln('    ),');
    }
    buffer
      ..writeln('  };')
      ..writeln();

    // registerAll helper.
    buffer
      ..writeln(
          '  /// Ensures every annotated model is downloaded + loaded.')
      ..writeln('  Future<void> registerAll(NsfwDetector detector) async {');
    for (final e in entries) {
      buffer.writeln(
          "    await detector.models.ensureReady('${_escape(e.annotation.id)}');");
    }
    buffer
      ..writeln('  }')
      ..writeln('}')
      ..writeln()
      ..writeln(
          '/// Convenience singleton — `${className}Registry().models`.')
      ..writeln('const $registryName ${_lowerFirst(className)}Registry =')
      ..writeln('    $registryName();');
  }

  String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  String _lowerFirst(String value) =>
      value.isEmpty ? value : value[0].toLowerCase() + value.substring(1);
}

class _ModelEntry {
  _ModelEntry({required this.fieldName, required this.annotation});

  final String fieldName;
  final _ParsedAnnotation annotation;
}

class _ParsedAnnotation {
  _ParsedAnnotation({
    required this.id,
    required this.defaultThreshold,
    required this.defaultMode,
    required this.displayName,
    required this.tags,
  });

  final String id;
  final double defaultThreshold;
  final String defaultMode; // ScanMode enum name
  final String? displayName;
  final Set<String> tags;
}

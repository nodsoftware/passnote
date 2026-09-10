import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:conclave/conclave.dart';
import 'package:source_gen/source_gen.dart';

/// Generates, for every `@Document()` class, the three artefacts a Conclave
/// collection needs — kept in sync by construction:
///
/// - `_$XCodec`, a `Codec<X>` whose `toMap` / `fromMap` cover the class's
///   instance fields through its unnamed constructor, and whose `idOf` reads
///   the `@DocumentId()` field;
/// - `_$XSchema`, the `Map<String, CrdtType>` from the `@Crdt(...)`
///   annotations (unannotated fields merge last-write-wins);
/// - `_$XMergeStrategy`, a const `SchemaMergeStrategy` over that schema.
class DocumentGenerator extends GeneratorForAnnotation<Document> {
  static const _documentId = TypeChecker.typeNamed(
    DocumentId,
    inPackage: 'conclave',
  );
  static const _crdt = TypeChecker.typeNamed(Crdt, inPackage: 'conclave');

  @override
  String generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element is! ClassElement) {
      throw InvalidGenerationSource(
        '@Document() annotates classes; `${element.displayName}` is not one.',
        element: element,
      );
    }
    final name = element.displayName;
    final fields = [
      for (final f in element.fields)
        // Real declared instance fields only — not statics, and not the
        // synthetic backing fields of explicit getters.
        if (!f.isStatic && f.isOriginDeclaration) f,
    ];
    if (fields.isEmpty) {
      throw InvalidGenerationSource(
        '@Document() class $name has no instance fields to serialize.',
        element: element,
      );
    }

    final idField = _idFieldOf(name, fields);
    final schema = _schemaOf(name, fields);
    final ctor = _unnamedConstructorOf(name, element, fields);

    final buffer = StringBuffer();

    // Schema and merge strategy. A model is free to reference only some of
    // the generated artefacts, so the optional ones carry unused ignores.
    buffer
      ..writeln('// ignore: unused_element')
      ..writeln('const Map<String, CrdtType> _\$${name}Schema = '
          '<String, CrdtType>{');
    for (final entry in schema.entries) {
      buffer.writeln("  '${entry.key}': ${entry.value},");
    }
    buffer
      ..writeln('};')
      ..writeln()
      ..writeln('// ignore: unused_element')
      ..writeln('const MergeStrategy _\$${name}MergeStrategy = '
          'SchemaMergeStrategy(_\$${name}Schema);')
      ..writeln();

    // Codec.
    buffer
      ..writeln('final Codec<$name> _\$${name}Codec = JsonCodec<$name>(')
      ..writeln('  toMap: _\$${name}ToMap,')
      ..writeln('  fromMap: _\$${name}FromMap,')
      ..writeln('  idOf: ($name instance) => instance.${idField.displayName},')
      ..writeln(');')
      ..writeln();

    // toMap.
    buffer.writeln('Map<String, dynamic> _\$${name}ToMap($name instance) => '
        '<String, dynamic>{');
    for (final f in fields) {
      buffer.writeln("  '${f.displayName}': instance.${f.displayName},");
    }
    buffer
      ..writeln('};')
      ..writeln();

    // fromMap, through the unnamed constructor.
    buffer.writeln('$name _\$${name}FromMap(Map<String, dynamic> map) => '
        '$name(');
    for (final param in ctor.formalParameters) {
      final field = fields.firstWhere(
        (f) => f.displayName == param.displayName,
      );
      final expr = _decodeExpression(
        name,
        field,
        param.hasDefaultValue ? param.defaultValueCode : null,
      );
      buffer.writeln(
        param.isNamed ? '  ${param.displayName}: $expr,' : '  $expr,',
      );
    }
    buffer.writeln(');');

    return buffer.toString();
  }

  /// The single `@DocumentId()` field, validated to be a non-nullable String.
  FieldElement _idFieldOf(String name, List<FieldElement> fields) {
    final idFields = [
      for (final f in fields)
        if (_documentId.firstAnnotationOfExact(f) != null) f,
    ];
    if (idFields.length != 1) {
      throw InvalidGenerationSource(
        '@Document() class $name needs exactly one @DocumentId() field; '
        'found ${idFields.length}.',
      );
    }
    final id = idFields.single;
    if (!id.type.isDartCoreString ||
        id.type.nullabilitySuffix != NullabilitySuffix.none) {
      throw InvalidGenerationSource(
        '@DocumentId() field $name.${id.displayName} must be a non-nullable '
        'String.',
      );
    }
    return id;
  }

  /// The `@Crdt(...)` schema, with the type argument validated against the
  /// field's Dart type.
  Map<String, String> _schemaOf(String name, List<FieldElement> fields) {
    final schema = <String, String>{};
    for (final f in fields) {
      final marker = _crdt.firstAnnotationOfExact(f);
      if (marker == null) continue;
      final typeName =
          marker.getField('type')?.type?.element?.displayName ?? '';
      switch (typeName) {
        case 'LwwRegister':
          break; // The default; recording it is allowed but redundant.
        case 'PnCounter':
          if (!f.type.isDartCoreNum &&
              !f.type.isDartCoreInt &&
              !f.type.isDartCoreDouble) {
            throw InvalidGenerationSource(
              '@Crdt(PnCounter()) field $name.${f.displayName} must be a '
              'number (its value is the counter total).',
            );
          }
          schema[f.displayName] = 'PnCounter()';
        case 'OrSet':
          if (!f.type.isDartCoreList) {
            throw InvalidGenerationSource(
              '@Crdt(OrSet()) field $name.${f.displayName} must be a List '
              '(its value is the set membership).',
            );
          }
          schema[f.displayName] = 'OrSet()';
        default:
          throw InvalidGenerationSource(
            '@Crdt on $name.${f.displayName} carries an unknown CrdtType '
            '"$typeName".',
          );
      }
    }
    return schema;
  }

  /// The unnamed constructor, validated to cover every serialized field by a
  /// same-named parameter.
  ConstructorElement _unnamedConstructorOf(
    String name,
    ClassElement element,
    List<FieldElement> fields,
  ) {
    final ctor = element.constructors
        .where((c) => c.displayName == name || c.displayName == 'new')
        .firstOrNull;
    if (ctor == null) {
      throw InvalidGenerationSource(
        '@Document() class $name needs an unnamed constructor.',
        element: element,
      );
    }
    final fieldNames = {for (final f in fields) f.displayName};
    final paramNames = {
      for (final p in ctor.formalParameters) p.displayName,
    };
    final missing = fieldNames.difference(paramNames);
    if (missing.isNotEmpty) {
      throw InvalidGenerationSource(
        '@Document() class $name: the unnamed constructor has no parameter '
        'for ${missing.map((m) => '"$m"').join(', ')}, so a stored document '
        'cannot be reconstructed.',
      );
    }
    final extra = paramNames.difference(fieldNames);
    if (extra.isNotEmpty) {
      throw InvalidGenerationSource(
        '@Document() class $name: constructor parameter(s) '
        '${extra.map((m) => '"$m"').join(', ')} match no serialized field.',
      );
    }
    return ctor;
  }

  /// The Dart expression that decodes `map['<field>']` back into the field's
  /// type. [defaultCode] (the constructor parameter's default) is used when
  /// the stored document lacks the field.
  String _decodeExpression(
    String name,
    FieldElement field,
    String? defaultCode,
  ) {
    final access = "map['${field.displayName}']";
    final type = field.type;
    final nullable = type.nullabilitySuffix != NullabilitySuffix.none;

    String withDefault(String nullableExpr, String plainExpr) {
      if (defaultCode != null) return '$nullableExpr ?? $defaultCode';
      return nullable ? nullableExpr : plainExpr;
    }

    if (type.isDartCoreString) {
      return withDefault('$access as String?', '$access as String');
    }
    if (type.isDartCoreBool) {
      return withDefault('$access as bool?', '$access as bool');
    }
    if (type.isDartCoreNum) {
      return withDefault('$access as num?', '$access as num');
    }
    if (type.isDartCoreInt) {
      return withDefault(
        '($access as num?)?.toInt()',
        '($access as num).toInt()',
      );
    }
    if (type.isDartCoreDouble) {
      return withDefault(
        '($access as num?)?.toDouble()',
        '($access as num).toDouble()',
      );
    }
    if (type.isDartCoreList) {
      final arg = _scalarArgOf(name, field, type as InterfaceType, 0);
      // int / double elements are converted, not cast: JSON gives back `num`s
      // whose runtime type is not guaranteed (an integral double decodes as
      // int when compiled to JavaScript).
      final convert = _numConversionOf(arg);
      if (convert != null) {
        return withDefault(
          '($access as List?)?.map((e) => (e as num).$convert()).toList()',
          '($access as List).map((e) => (e as num).$convert()).toList()',
        );
      }
      return withDefault(
        '($access as List?)?.cast<$arg>()',
        '($access as List).cast<$arg>()',
      );
    }
    if (type.isDartCoreMap) {
      final interface = type as InterfaceType;
      final keyType = interface.typeArguments[0];
      if (!keyType.isDartCoreString) {
        throw InvalidGenerationSource(
          'Field $name.${field.displayName}: map keys must be String '
          '(documents are JSON).',
        );
      }
      final arg = _scalarArgOf(name, field, interface, 1);
      final convert = _numConversionOf(arg);
      if (convert != null) {
        return withDefault(
          '($access as Map?)?.map((k, v) => MapEntry(k as String, '
              '(v as num).$convert()))',
          '($access as Map).map((k, v) => MapEntry(k as String, '
              '(v as num).$convert()))',
        );
      }
      return withDefault(
        '($access as Map?)?.cast<String, $arg>()',
        '($access as Map).cast<String, $arg>()',
      );
    }
    throw InvalidGenerationSource(
      'Field $name.${field.displayName} has unsupported type "$type". '
      'Supported: String, int, double, num, bool, their nullable forms, '
      'List<scalar>, and Map<String, scalar>. Write a manual JsonCodec for '
      'other shapes.',
    );
  }

  /// The `num` conversion an element type needs, or `null` when a cast is
  /// exact.
  static String? _numConversionOf(String arg) => switch (arg) {
        'int' => 'toInt',
        'double' => 'toDouble',
        _ => null,
      };

  /// The validated scalar type argument of a List or Map field.
  String _scalarArgOf(
    String name,
    FieldElement field,
    InterfaceType type,
    int index,
  ) {
    final arg = type.typeArguments[index];
    final scalar = arg.isDartCoreString ||
        arg.isDartCoreBool ||
        arg.isDartCoreNum ||
        arg.isDartCoreInt ||
        arg.isDartCoreDouble ||
        arg is DynamicType;
    if (!scalar || arg.nullabilitySuffix != NullabilitySuffix.none) {
      throw InvalidGenerationSource(
        'Field $name.${field.displayName}: element type "$arg" is not a '
        'supported scalar (String, int, double, num, bool, or dynamic).',
      );
    }
    return arg.getDisplayString();
  }
}

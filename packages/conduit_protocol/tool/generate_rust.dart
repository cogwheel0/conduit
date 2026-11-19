// Writes desktop/crates/protocol/src/generated.rs: the protocol's DTOs,
// enums, error codes and method and event tables, as Rust.
//
//   dart run tool/generate_rust.dart           # write it
//   dart run tool/generate_rust.dart --check   # exit 1 when it is stale
//
// Reads this package's own source with package:analyzer -- the freezed
// declarations as written, not build_runner's output, so it needs no
// codegen and sees the doc comments. It understands the shapes this package
// uses and fails loudly on anything else, rather than guessing at a type.
//
// The output goes through the pinned rustfmt (desktop/rust-toolchain.toml),
// so a Rust toolchain must be on PATH.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

/// Hand-written in the crate, which the generated code refers to instead.
const Map<String, String> _handWritten = <String, String>{
  'RpcError': 'crate::RpcError',
};

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final package = Directory.fromUri(Platform.script.resolve('..'));
  final repo = package.parent.parent;
  final desktop = Directory('${repo.path}/desktop');
  final output = File('${desktop.path}/crates/protocol/src/generated.rs');

  final source = ProtocolSource.read(Directory('${package.path}/lib/src'));
  final rust = await _rustfmt(RustEmitter(source).emit(), desktop);

  if (check) {
    if (!output.existsSync() || output.readAsStringSync() != rust) {
      stderr.writeln(
        '${output.path} is stale: run `dart run tool/generate_rust.dart` '
        'in packages/conduit_protocol.',
      );
      exitCode = 1;
    }
    return;
  }
  output.writeAsStringSync(rust);
  stdout.writeln(
    'Wrote ${source.dtos.length} structs, ${source.enums.length} enums, '
    '${source.methods.length} methods and ${source.events.length} events '
    'to ${output.path}',
  );
}

// ---------------------------------------------------------------------------
// Reading the Dart source
// ---------------------------------------------------------------------------

/// A Dart type as written: `List<ChatSummary>?`.
final class TypeRef {
  TypeRef(this.name, this.args, {required this.nullable});

  factory TypeRef.of(TypeAnnotation? node, String where) {
    if (node is! NamedType) {
      throw GeneratorError('$where: unsupported type `$node`');
    }
    if (node.importPrefix != null) {
      throw GeneratorError('$where: prefixed type `$node`');
    }
    return TypeRef(node.name.lexeme, <TypeRef>[
      for (final arg in node.typeArguments?.arguments ?? <TypeAnnotation>[])
        TypeRef.of(arg, where),
    ], nullable: node.question != null);
  }

  final String name;
  final List<TypeRef> args;
  final bool nullable;

  /// `dynamic` and `Object`: any JSON, null included.
  bool get isAny => name == 'dynamic' || name == 'Object';

  TypeRef get nonNull => TypeRef(name, args, nullable: false);

  @override
  String toString() =>
      '$name${args.isEmpty ? '' : '<${args.join(', ')}>'}'
      '${nullable ? '?' : ''}';
}

final class DtoField {
  DtoField({
    required this.name,
    required this.type,
    required this.defaultValue,
    required this.includeIfNull,
    required this.jsonName,
    required this.docs,
  });

  final String name;
  final TypeRef type;
  final Expression? defaultValue;
  final bool includeIfNull;
  final String jsonName;
  final List<String> docs;

  /// Absent or null on the wire, which Rust spells `Option`.
  bool get isOptional => type.nullable || type.name == 'dynamic';
}

final class Dto {
  Dto(this.name, this.docs, this.fields);

  final String name;
  final List<String> docs;
  final List<DtoField> fields;
}

final class EnumValue {
  EnumValue(this.name, this.wire, this.docs);

  final String name;
  final String wire;
  final List<String> docs;
}

final class EnumDef {
  EnumDef(this.name, this.docs, this.values);

  final String name;
  final List<String> docs;
  final List<EnumValue> values;
}

/// A `static const String` in one of the name classes.
final class NamedConst {
  NamedConst(this.field, this.value, this.docs);

  final String field;
  final String value;
  final List<String> docs;
}

final class MethodSpecDef {
  MethodSpecDef(this.field, this.name, this.params, this.result, this.docs);

  final String field;
  final String name;
  final String? params;
  final String? result;
  final List<String> docs;
}

final class EventSpecDef {
  EventSpecDef(
    this.field,
    this.name,
    this.payload,
    this.docs, {
    required this.scoped,
  });

  final String field;
  final String name;
  final String? payload;
  final bool scoped;
  final List<String> docs;
}

final class GeneratorError implements Exception {
  GeneratorError(this.message);

  final String message;

  @override
  String toString() => 'generate_rust: $message';
}

/// Everything the generator needs from `lib/src`, in a stable order: files
/// by name, declarations as written.
final class ProtocolSource {
  ProtocolSource._();

  factory ProtocolSource.read(Directory dir) {
    final source = ProtocolSource._();
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.dart') &&
                  !f.path.endsWith('.g.dart') &&
                  !f.path.endsWith('.freezed.dart'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final unit = parseFile(
        path: file.absolute.path,
        featureSet: FeatureSet.latestLanguageVersion(),
      ).unit;
      for (final declaration in unit.declarations) {
        source._read(declaration);
      }
    }
    source._readSpecs();
    return source;
  }

  final List<Dto> dtos = <Dto>[];
  final List<EnumDef> enums = <EnumDef>[];

  /// Enums and structs in the order the files declare them.
  final List<Object> declarations = <Object>[];
  final Map<String, Expression> topConsts = <String, Expression>{};
  final Map<String, List<String>> topDocs = <String, List<String>>{};

  /// `Class.field` -> initializer, for every static const.
  final Map<String, Expression> staticConsts = <String, Expression>{};

  /// The string constants of every class, by class, in order.
  final Map<String, List<NamedConst>> namedConsts =
      <String, List<NamedConst>>{};

  final List<MethodSpecDef> methods = <MethodSpecDef>[];
  final List<EventSpecDef> events = <EventSpecDef>[];

  final Map<String, ClassDeclaration> _specClasses =
      <String, ClassDeclaration>{};

  Dto? dto(String name) => dtos.where((d) => d.name == name).firstOrNull;
  EnumDef? enumDef(String name) =>
      enums.where((e) => e.name == name).firstOrNull;

  bool isType(String name) =>
      dto(name) != null ||
      enumDef(name) != null ||
      _handWritten.containsKey(name);

  String topString(String name) {
    final value = topConsts[name];
    if (value is! StringLiteral || value.stringValue == null) {
      throw GeneratorError('$name is not a string constant');
    }
    return value.stringValue!;
  }

  void _read(CompilationUnitMember declaration) {
    switch (declaration) {
      case TopLevelVariableDeclaration(:final variables) when variables.isConst:
        for (final variable in variables.variables) {
          topConsts[variable.name.lexeme] = variable.initializer!;
          topDocs[variable.name.lexeme] = _docs(
            declaration.documentationComment,
          );
        }
      case EnumDeclaration():
        final def = _readEnum(declaration);
        enums.add(def);
        declarations.add(def);
      case ClassDeclaration():
        _readClass(declaration);
      default:
        break;
    }
  }

  EnumDef _readEnum(EnumDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    var rename = 'none';
    for (final annotation in node.metadata) {
      if (annotation.name.name != 'JsonEnum') continue;
      for (final arg in annotation.arguments?.arguments ?? <Argument>[]) {
        if (arg is NamedArgument && arg.name.lexeme == 'fieldRename') {
          final value = arg.argumentExpression;
          if (value is! PrefixedIdentifier) {
            throw GeneratorError('$name: unsupported fieldRename');
          }
          rename = value.identifier.name;
        } else {
          throw GeneratorError('$name: unsupported @JsonEnum argument `$arg`');
        }
      }
    }
    if (node.body.members.isNotEmpty) {
      throw GeneratorError('$name: enums with members are not supported');
    }
    return EnumDef(name, _docs(node.documentationComment), <EnumValue>[
      for (final constant in node.body.constants)
        EnumValue(
          constant.name.lexeme,
          _jsonValue(constant.metadata) ??
              _renameEnumValue(constant.name.lexeme, rename, name),
          _docs(constant.documentationComment),
        ),
    ]);
  }

  static String? _jsonValue(List<Annotation> metadata) {
    for (final annotation in metadata) {
      if (annotation.name.name != 'JsonValue') continue;
      final value = annotation.arguments!.arguments.single;
      if (value is! StringLiteral || value.stringValue == null) {
        throw GeneratorError('@JsonValue must be a string literal: $value');
      }
      return value.stringValue;
    }
    return null;
  }

  static String _renameEnumValue(String value, String rename, String where) =>
      switch (rename) {
        'none' => value,
        'snake' => _snake(value),
        'screamingSnake' => _snake(value).toUpperCase(),
        'kebab' => _snake(value).replaceAll('_', '-'),
        'pascal' => _pascal(value),
        _ => throw GeneratorError('$where: unsupported fieldRename $rename'),
      };

  void _readClass(ClassDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    final members = switch (node.body) {
      BlockClassBody(:final members) => members,
      _ => const <ClassMember>[],
    };
    for (final member in members) {
      if (member is! FieldDeclaration || !member.isStatic) continue;
      if (!member.fields.isConst) continue;
      for (final variable in member.fields.variables) {
        final initializer = variable.initializer!;
        staticConsts['$name.${variable.name.lexeme}'] = initializer;
        if (initializer is StringLiteral && initializer.stringValue != null) {
          (namedConsts[name] ??= <NamedConst>[]).add(
            NamedConst(
              variable.name.lexeme,
              initializer.stringValue!,
              _docs(member.documentationComment),
            ),
          );
        }
      }
    }
    if (name == 'ConduitMethodSpecs' || name == 'ConduitEventSpecs') {
      _specClasses[name] = node;
    }
    final isFreezed = node.metadata.any(
      (a) => a.name.name == 'freezed' || a.name.name == 'Freezed',
    );
    if (!isFreezed) return;
    if (node.metadata.any((a) => a.name.name == 'JsonSerializable')) {
      throw GeneratorError('$name: @JsonSerializable is not supported');
    }
    final factories = members
        .whereType<ConstructorDeclaration>()
        .where(
          (c) => c.factoryKeyword != null && c.redirectedConstructor != null,
        )
        .toList();
    if (factories.length != 1 || factories.single.name != null) {
      throw GeneratorError(
        '$name: expected exactly one unnamed redirecting factory (unions are '
        'not supported)',
      );
    }
    final fields = <DtoField>[];
    for (final param in factories.single.parameters.parameters) {
      final field = param.name!.lexeme;
      final where = '$name.$field';
      if (!param.isNamed) throw GeneratorError('$where: positional parameter');
      Expression? defaultValue;
      var includeIfNull = false;
      String? jsonName;
      for (final annotation in param.metadata) {
        switch (annotation.name.name) {
          case 'Default':
            defaultValue = annotation.arguments!.arguments.single as Expression;
          case 'JsonKey':
            for (final arg in annotation.arguments!.arguments) {
              if (arg is! NamedArgument) {
                throw GeneratorError('$where: unsupported @JsonKey');
              }
              final value = arg.argumentExpression;
              switch (arg.name.lexeme) {
                case 'includeIfNull' when value is BooleanLiteral:
                  includeIfNull = value.value;
                case 'name' when value is StringLiteral:
                  jsonName = value.stringValue;
                default:
                  throw GeneratorError(
                    '$where: unsupported @JsonKey(${arg.name.lexeme}: ...)',
                  );
              }
            }
          default:
            throw GeneratorError(
              '$where: unsupported annotation @${annotation.name.name}',
            );
        }
      }
      final type = TypeRef.of(param.type, where);
      if (!param.isRequired &&
          defaultValue == null &&
          !type.nullable &&
          type.name != 'dynamic') {
        throw GeneratorError('$where: optional, non-nullable and no @Default');
      }
      fields.add(
        DtoField(
          name: field,
          type: type,
          defaultValue: defaultValue,
          includeIfNull: includeIfNull,
          jsonName: jsonName ?? field,
          docs: _docs(param.documentationComment),
        ),
      );
    }
    final dto = Dto(name, _docs(node.documentationComment), fields);
    dtos.add(dto);
    declarations.add(dto);
  }

  void _readSpecs() {
    NamedConst nameConst(Expression node, String nameClass, String where) {
      if (node is! PrefixedIdentifier || node.prefix.name != nameClass) {
        throw GeneratorError('$where: expected $nameClass.<name>, got $node');
      }
      final constant = namedConsts[nameClass]
          ?.where((c) => c.field == node.identifier.name)
          .firstOrNull;
      if (constant == null) throw GeneratorError('$where: unknown $node');
      return constant;
    }

    for (final (specClass, specType, nameClass) in <(String, String, String)>[
      ('ConduitMethodSpecs', 'ConduitMethodSpec', 'ConduitMethods'),
      ('ConduitEventSpecs', 'ConduitEventSpec', 'ConduitEvents'),
    ]) {
      final node = _specClasses[specClass];
      if (node == null) throw GeneratorError('$specClass not found');
      final specs = <String, (FieldDeclaration, VariableDeclaration)>{};
      List<String>? order;
      for (final member in (node.body as BlockClassBody).members) {
        if (member is! FieldDeclaration || !member.fields.isConst) continue;
        for (final variable in member.fields.variables) {
          if (variable.name.lexeme == 'all') {
            final list = variable.initializer as ListLiteral;
            order = <String>[
              for (final element in list.elements)
                (element as SimpleIdentifier).name,
            ];
          } else {
            specs[variable.name.lexeme] = (member, variable);
          }
        }
      }
      if (order == null) throw GeneratorError('$specClass.all not found');
      if (order.toSet().length != order.length ||
          order.toSet().difference(specs.keys.toSet()).isNotEmpty ||
          specs.keys.toSet().difference(order.toSet()).isNotEmpty) {
        throw GeneratorError('$specClass.all must list every spec once');
      }
      for (final field in order) {
        final (member, variable) = specs[field]!;
        final where = '$specClass.$field';
        final (typeArgs, arguments) = switch (variable.initializer) {
          MethodInvocation(
            :final methodName,
            :final typeArguments,
            :final argumentList,
          )
              when methodName.name == specType =>
            (typeArguments, argumentList),
          InstanceCreationExpression(
            :final constructorName,
            :final argumentList,
          )
              when constructorName.type.name.lexeme == specType =>
            (constructorName.type.typeArguments, argumentList),
          _ => throw GeneratorError('$where: expected $specType<...>(...)'),
        };
        final types = <String>[
          for (final arg in typeArgs?.arguments ?? <TypeAnnotation>[])
            TypeRef.of(arg, where).name,
        ];
        final positional = arguments.arguments.whereType<Expression>().toList();
        final named = <String, Expression>{
          for (final arg in arguments.arguments.whereType<NamedArgument>())
            arg.name.lexeme: arg.argumentExpression,
        };
        String? decoded(String key, String type) {
          final decoder = named[key];
          if (decoder == null) {
            if (type != 'void') {
              throw GeneratorError('$where: $type without a `$key:` decoder');
            }
            return null;
          }
          if (decoder is! PrefixedIdentifier ||
              decoder.identifier.name != 'fromJson' ||
              decoder.prefix.name != type) {
            throw GeneratorError('$where: `$key:` must be $type.fromJson');
          }
          if (!isType(type)) throw GeneratorError('$where: unknown DTO $type');
          return type;
        }

        final constant = nameConst(positional.single, nameClass, where);
        final own = _docs(member.documentationComment);
        final docs = <String>[
          ...constant.docs,
          if (constant.docs.isNotEmpty && own.isNotEmpty) '',
          ...own,
        ];
        if (specClass == 'ConduitMethodSpecs') {
          if (types.length != 2) throw GeneratorError('$where: <P, R> needed');
          methods.add(
            MethodSpecDef(
              constant.field,
              constant.value,
              decoded('params', types[0]),
              decoded('result', types[1]),
              docs,
            ),
          );
        } else {
          if (types.length != 1) throw GeneratorError('$where: <T> needed');
          final scoped = named['scoped'];
          if (scoped is! BooleanLiteral) {
            throw GeneratorError('$where: scoped must be a bool literal');
          }
          events.add(
            EventSpecDef(
              constant.field,
              constant.value,
              decoded('payload', types[0]),
              docs,
              scoped: scoped.value,
            ),
          );
        }
      }
    }
  }
}

/// A doc comment's lines with `///` stripped, dartdoc references turned
/// into code spans (`[Foo]` means nothing to rustdoc), and untagged code
/// fences marked `text` so rustdoc does not compile them as doctests.
List<String> _docs(Comment? comment) {
  if (comment == null) return const <String>[];
  final reference = RegExp(
    r'\[([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\](?![(\[])',
  );
  final lines = <String>[];
  var inFence = false;
  for (final token in comment.tokens) {
    final lexeme = token.lexeme;
    if (!lexeme.startsWith('///')) {
      throw GeneratorError('unsupported doc comment `$lexeme`');
    }
    var line = lexeme.substring(3);
    if (line.startsWith(' ')) line = line.substring(1);
    line = line.trimRight();
    if (line.trimLeft().startsWith('```')) {
      if (!inFence && line.trimLeft() == '```') {
        line = line.replaceFirst('```', '```text');
      }
      inFence = !inFence;
    } else if (!inFence) {
      line = _outsideCodeSpans(
        line,
        (text) => text.replaceAllMapped(reference, (m) => '`${m[1]}`'),
      );
    }
    lines.add(line);
  }
  return lines;
}

String _outsideCodeSpans(String line, String Function(String) transform) {
  final parts = line.split('`');
  return <String>[
    for (var i = 0; i < parts.length; i++)
      i.isEven ? transform(parts[i]) : parts[i],
  ].join('`');
}

// ---------------------------------------------------------------------------
// Writing Rust
// ---------------------------------------------------------------------------

const Set<String> _rustKeywords = <String>{
  'as', 'break', 'const', 'continue', 'else', 'enum', 'extern', 'false', //
  'fn', 'for', 'if', 'impl', 'in', 'let', 'loop', 'match', 'mod', 'move',
  'mut', 'pub', 'ref', 'return', 'static', 'struct', 'trait', 'true', 'type',
  'unsafe', 'use', 'where', 'while', 'async', 'await', 'dyn', 'abstract',
  'become', 'box', 'do', 'final', 'macro', 'override', 'priv', 'typeof',
  'unsized', 'virtual', 'yield', 'try', 'gen',
};

/// Keywords that cannot be raw identifiers either.
const Set<String> _unrawable = <String>{'self', 'super', 'crate'};

final class RustEmitter {
  RustEmitter(this.source);

  final ProtocolSource source;
  final StringBuffer _out = StringBuffer();
  bool _usesBTreeMap = false;

  String emit() {
    _emitVersion();
    for (final item in source.declarations) {
      switch (item) {
        case EnumDef():
          _emitEnum(item);
        case Dto() when !_handWritten.containsKey(item.name):
          _emitStruct(item);
      }
    }
    _emitErrorCodes();
    _emitMethods();
    _emitEvents();
    _emitConformance();

    final header = StringBuffer()
      ..writeln(
        '// @generated by packages/conduit_protocol/tool/generate_rust.dart '
        'from',
      )
      ..writeln(
        '// packages/conduit_protocol/lib/src. Do not edit by hand: change the '
        'Dart',
      )
      ..writeln('// source and run `dart run tool/generate_rust.dart` there.')
      ..writeln()
      ..writeln('use serde::{Deserialize, Serialize};')
      ..writeln(_usesBTreeMap ? 'use std::collections::BTreeMap;' : '')
      ..writeln()
      ..writeln('use crate::{EventSpec, MethodSpec};')
      ..writeln();
    return '$header$_out';
  }

  void _docs(List<String> lines, [String indent = '']) {
    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].isEmpty) {
      end--;
    }
    for (final line in lines.sublist(start, end)) {
      _out.writeln(line.isEmpty ? '$indent///' : '$indent/// $line');
    }
  }

  void _emitVersion() {
    final version = source.topString('kConduitProtocolVersion');
    _docs(source.topDocs['kConduitProtocolVersion']!);
    _out
      ..writeln('pub const PROTOCOL_VERSION: &str = ${_str(version)};')
      ..writeln();
  }

  // Enums ------------------------------------------------------------------

  void _emitEnum(EnumDef def) {
    _docs(def.docs);
    _out
      ..writeln(
        '#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, '
        'Deserialize)]',
      )
      ..writeln('pub enum ${def.name} {');
    final variants = <String>{};
    for (final value in def.values) {
      if (!variants.add(_pascal(value.name))) {
        throw GeneratorError(
          '${def.name}: two values become ${_pascal(value.name)}',
        );
      }
    }
    // serde wants the fallback last; a Dart value called `unknown` doubles
    // as it, wherever the Dart enum declares it.
    final own = def.values
        .where((v) => _pascal(v.name) == 'Unknown')
        .firstOrNull;
    for (final value in def.values) {
      if (identical(value, own)) continue;
      _docs(value.docs, '    ');
      _out
        ..writeln('    #[serde(rename = ${_str(value.wire)})]')
        ..writeln('    ${_pascal(value.name)},');
    }
    if (own != null) {
      _docs(own.docs, '    ');
      if (own.docs.isNotEmpty) _out.writeln('    ///');
      _out
        ..writeln(
          '    /// Also what a value this build does not know decodes as.',
        )
        ..writeln('    #[serde(other, rename = ${_str(own.wire)})]')
        ..writeln('    Unknown,');
    } else {
      if (def.values.any((v) => v.wire == 'unknown')) {
        throw GeneratorError('${def.name}: a value already encodes "unknown"');
      }
      _out
        ..writeln(
          '    /// A value this build does not know, from a newer daemon. It '
          'decodes',
        )
        ..writeln(
          '    /// only: it encodes as `"unknown"`, which the daemon refuses.',
        )
        ..writeln('    #[serde(other, rename = "unknown")]')
        ..writeln('    Unknown,');
    }
    _out
      ..writeln('}')
      ..writeln();
  }

  // Structs ----------------------------------------------------------------

  void _emitStruct(Dto dto) {
    final defaults = <String>[];
    // Every field optional or defaulted: the struct has a Default, which
    // derive writes when each default is Rust's own.
    final allDefaultable = dto.fields.every(
      (f) => f.isOptional || f.defaultValue != null,
    );
    final derivable =
        allDefaultable &&
        dto.fields.every(
          (f) => f.isOptional || _isRustDefault(f.defaultValue!, f.type),
        );

    _docs(dto.docs);
    _out
      ..writeln(
        '#[derive(Debug, Clone, PartialEq, Serialize, Deserialize'
        '${derivable ? ', Default' : ''})]',
      )
      ..writeln('#[serde(rename_all = "camelCase")]')
      ..writeln('pub struct ${dto.name} {');
    for (final field in dto.fields) {
      final ident = _fieldIdent(field.name);
      final type = _fieldType(field);
      final attrs = <String>[];
      if (_serdeCamel(ident) != field.jsonName) {
        attrs.add('rename = ${_str(field.jsonName)}');
      }
      if (field.isOptional) {
        if (field.defaultValue != null && field.defaultValue is! NullLiteral) {
          throw GeneratorError(
            '${dto.name}.${field.name}: a non-null default on a nullable '
            'field is not supported',
          );
        }
        attrs.add('default');
        if (!field.includeIfNull) {
          attrs.add('skip_serializing_if = "Option::is_none"');
        }
      } else if (field.defaultValue != null) {
        if (_isRustDefault(field.defaultValue!, field.type)) {
          attrs.add('default');
        } else {
          final fn = _defaultFn(dto, field);
          final value = _value(
            field.defaultValue!,
            field.type,
            '${dto.name}.${field.name}',
          );
          defaults.add('fn $fn() -> $type {\n    $value\n}');
          attrs.add('default = ${_str(fn)}');
        }
      }
      _docs(field.docs, '    ');
      if (attrs.isNotEmpty) _out.writeln('    #[serde(${attrs.join(', ')})]');
      _out.writeln('    pub $ident: $type,');
    }
    _out
      ..writeln('}')
      ..writeln();

    if (allDefaultable && !derivable) {
      _out
        ..writeln('impl Default for ${dto.name} {')
        ..writeln('    fn default() -> Self {')
        ..writeln('        Self {');
      for (final field in dto.fields) {
        final ident = _fieldIdent(field.name);
        final value = field.isOptional
            ? 'None'
            : _isRustDefault(field.defaultValue!, field.type)
            ? 'Default::default()'
            : '${_defaultFn(dto, field)}()';
        _out.writeln('            $ident: $value,');
      }
      _out
        ..writeln('        }')
        ..writeln('    }')
        ..writeln('}')
        ..writeln();
    }
    for (final fn in defaults) {
      _out
        ..writeln(fn)
        ..writeln();
    }
  }

  String _defaultFn(Dto dto, DtoField field) =>
      'default_${_snake(dto.name)}_${_snake(field.name)}';

  String _fieldType(DtoField field) {
    if (field.isOptional) {
      return 'Option<${_rustType(field.type.nonNull, field.name)}>';
    }
    return _rustType(field.type, field.name);
  }

  /// The Rust type for a non-null Dart type.
  String _rustType(TypeRef type, String where) {
    switch (type.name) {
      case 'String':
        return 'String';
      case 'bool':
        return 'bool';
      case 'int':
        return 'i64';
      case 'double' || 'num':
        return 'f64';
      case 'dynamic' || 'Object':
        return 'serde_json::Value';
      case 'List':
        return 'Vec<${_elementType(type.args.single, where)}>';
      case 'Map':
        final key = type.args[0];
        if (key.name != 'String' || key.nullable) {
          throw GeneratorError('$where: map keys must be String');
        }
        // An untyped map is a JSON object; keep it as one.
        if (type.args[1].isAny) return 'serde_json::Value';
        _usesBTreeMap = true;
        return 'BTreeMap<String, ${_elementType(type.args[1], where)}>';
    }
    final handWritten = _handWritten[type.name];
    if (handWritten != null) return handWritten;
    if (source.isType(type.name)) return type.name;
    throw GeneratorError('$where: no Rust type for `$type`');
  }

  String _elementType(TypeRef type, String where) =>
      type.nullable && !type.isAny
      ? 'Option<${_rustType(type.nonNull, where)}>'
      : _rustType(type, where);

  // Default values -----------------------------------------------------------

  /// Follows a constant reference to its value: `kDefaultUiFontSize`,
  /// `Capabilities.none`. Enum values are left alone.
  Expression _resolve(Expression node) {
    for (var depth = 0; depth < 16; depth++) {
      final next = switch (node) {
        SimpleIdentifier(:final name) => source.topConsts[name],
        PrefixedIdentifier(:final prefix, :final identifier)
            when source.enumDef(prefix.name) == null =>
          source.staticConsts['${prefix.name}.${identifier.name}'],
        _ => null,
      };
      if (next == null) return node;
      node = next;
    }
    throw GeneratorError('constant cycle at $node');
  }

  /// Whether [node] is what Rust's `Default::default()` gives [type].
  bool _isRustDefault(Expression node, TypeRef type) {
    final value = _resolve(node);
    return switch (value) {
      BooleanLiteral(value: false) => true,
      IntegerLiteral(:final value) => value == 0,
      DoubleLiteral(:final value) => value == 0,
      SimpleStringLiteral(:final value) => value.isEmpty,
      ListLiteral(:final elements) => elements.isEmpty,
      SetOrMapLiteral(:final elements) =>
        elements.isEmpty && !(type.name == 'Map' && type.args[1].isAny),
      // `Foo()`: the generated Default for Foo, which is Dart's `Foo()`.
      MethodInvocation(:final argumentList) ||
      InstanceCreationExpression(
        :final argumentList,
      ) => argumentList.arguments.isEmpty && _constructed(value) == type.name,
      _ => false,
    };
  }

  String? _constructed(Expression node) => switch (node) {
    MethodInvocation(:final target, :final methodName) when target == null =>
      methodName.name,
    InstanceCreationExpression(:final constructorName)
        when constructorName.name == null =>
      constructorName.type.name.lexeme,
    _ => null,
  };

  /// [node] as a Rust expression of [type]'s Rust type.
  String _value(Expression node, TypeRef type, String where) {
    final value = _resolve(node);
    if (value is NullLiteral) {
      if (!type.nullable) throw GeneratorError('$where: null for $type');
      return 'None';
    }
    if (type.nullable && !type.isAny) {
      return 'Some(${_value(value, type.nonNull, where)})';
    }
    Never fail() =>
        throw GeneratorError('$where: unsupported default `$node` for $type');
    switch (type.name) {
      case 'bool':
        return value is BooleanLiteral ? '${value.value}' : fail();
      case 'int':
        return switch (value) {
          IntegerLiteral(value: final int number) => '$number',
          PrefixExpression(
            operator: Token(lexeme: '-'),
            operand: IntegerLiteral(value: final int number),
          ) =>
            '-$number',
          _ => fail(),
        };
      case 'double' || 'num':
        final number = switch (value) {
          IntegerLiteral(value: final int number) => number.toDouble(),
          DoubleLiteral(value: final number) => number,
          _ => fail(),
        };
        final text = '$number';
        return text.contains('.') || text.contains('e') ? text : '$text.0';
      case 'String':
        if (value is! SimpleStringLiteral) fail();
        return value.value.isEmpty
            ? 'String::new()'
            : '${_str(value.value)}.to_owned()';
      case 'List':
        if (value is! ListLiteral) fail();
        if (value.elements.isEmpty) return 'Vec::new()';
        final elements = <String>[
          for (final element in value.elements)
            _value(element as Expression, type.args.single, where),
        ];
        return 'vec![${elements.join(', ')}]';
      case 'Map':
        if (value is! SetOrMapLiteral || value.elements.isNotEmpty) fail();
        return type.args[1].isAny
            ? 'serde_json::Value::Object(serde_json::Map::new())'
            : 'BTreeMap::new()';
    }
    final enumDef = source.enumDef(type.name);
    if (enumDef != null) {
      if (value is PrefixedIdentifier &&
          value.prefix.name == enumDef.name &&
          enumDef.values.any((v) => v.name == value.identifier.name)) {
        return '${enumDef.name}::${_pascal(value.identifier.name)}';
      }
      fail();
    }
    final dto = source.dto(type.name);
    if (dto == null || _constructed(value) != dto.name) fail();
    final args = switch (value) {
      MethodInvocation(:final argumentList) => argumentList.arguments,
      InstanceCreationExpression(:final argumentList) => argumentList.arguments,
      _ => fail(),
    };
    if (args.isEmpty) return '${dto.name}::default()';
    final fields = <String>[];
    for (final arg in args) {
      if (arg is! NamedArgument) fail();
      final field = dto.fields.firstWhere((f) => f.name == arg.name.lexeme);
      final fieldValue = _value(
        arg.argumentExpression,
        field.type,
        '$where.${field.name}',
      );
      fields.add('${_fieldIdent(field.name)}: $fieldValue');
    }
    return '${dto.name} { ${fields.join(', ')}, ..${dto.name}::default() }';
  }

  // Error codes --------------------------------------------------------------

  void _emitErrorCodes() {
    final codes = source.namedConsts['ConduitErrorCodes']!;
    _out
      ..writeln(
        '/// A stable error identifier: what `RpcError.code` carries. The app',
      )
      ..writeln('/// localizes each one; the daemon never sends prose.')
      ..writeln('#[derive(Debug, Clone, PartialEq, Eq, Hash)]')
      ..writeln('pub enum ErrorCode {');
    for (final code in codes) {
      _docs(<String>[
        ...code.docs,
        if (code.docs.isNotEmpty) '',
        '`${code.value}`',
      ], '    ');
      _out.writeln('    ${_pascal(code.field)},');
    }
    _out
      ..writeln('    /// A code this build does not know, kept as it came.')
      ..writeln('    Other(String),')
      ..writeln('}')
      ..writeln()
      ..writeln('impl ErrorCode {')
      ..writeln('    /// The code as it goes on the wire.')
      ..writeln('    pub fn as_str(&self) -> &str {')
      ..writeln('        match self {');
    for (final code in codes) {
      _out.writeln(
        '            Self::${_pascal(code.field)} => ${_str(code.value)},',
      );
    }
    _out
      ..writeln('            Self::Other(code) => code,')
      ..writeln('        }')
      ..writeln('    }')
      ..writeln()
      ..writeln(
        '    /// Reads a wire code; one this build does not know is '
        '[`ErrorCode::Other`].',
      )
      ..writeln('    pub fn from_code(code: &str) -> Self {')
      ..writeln('        match code {');
    for (final code in codes) {
      _out.writeln(
        '            ${_str(code.value)} => Self::${_pascal(code.field)},',
      );
    }
    _out
      ..writeln('            other => Self::Other(other.to_owned()),')
      ..writeln('        }')
      ..writeln('    }')
      ..writeln('}')
      ..writeln();
  }

  // Methods ------------------------------------------------------------------

  String _dtoPath(String? name, String none) =>
      name == null ? none : _handWritten[name] ?? 'super::$name';

  void _emitMethods() {
    final usesNoParams = source.methods.any((m) => m.params == null);
    final usesNoResult = source.methods.any((m) => m.result == null);
    _out
      ..writeln(
        '/// The RPC methods, one zero-sized type each, so a call is typed by '
        'its',
      )
      ..writeln(
        '/// method: `M::NAME` goes on the wire with an `M::Params`, and the '
        'reply',
      )
      ..writeln('/// decodes as an `M::Result`.')
      ..writeln('pub mod methods {')
      ..writeln('    use crate::RpcMethod;');
    if (usesNoParams || usesNoResult) {
      final names = <String>[
        if (usesNoParams) 'NoParams',
        if (usesNoResult) 'NoResult',
      ];
      _out.writeln(
        names.length == 1
            ? '    use crate::${names.single};'
            : '    use crate::{${names.join(', ')}};',
      );
    }
    _out.writeln();
    for (final method in source.methods) {
      final type = _pascal(method.field);
      _docs(<String>[
        ...method.docs,
        if (method.docs.isNotEmpty) '',
        '`${method.name}`: ${method.params ?? 'no params'} -> '
            '${method.result ?? 'no result'}.',
      ], '    ');
      _out
        ..writeln(
          '    #[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]',
        )
        ..writeln('    pub struct $type;')
        ..writeln()
        ..writeln('    impl RpcMethod for $type {')
        ..writeln("        const NAME: &'static str = ${_str(method.name)};")
        ..writeln(
          '        type Params = ${_dtoPath(method.params, 'NoParams')};',
        )
        ..writeln(
          '        type Result = ${_dtoPath(method.result, 'NoResult')};',
        )
        ..writeln('    }')
        ..writeln();
    }
    _out
      ..writeln('}')
      ..writeln()
      ..writeln(
        '/// Every method, with its params and result DTOs by name (`None` for '
        'none).',
      )
      ..writeln('pub const METHODS: &[MethodSpec] = &[');
    for (final method in source.methods) {
      _out
        ..writeln('    MethodSpec {')
        ..writeln('        name: ${_str(method.name)},')
        ..writeln('        params: ${_option(method.params)},')
        ..writeln('        result: ${_option(method.result)},')
        ..writeln('    },');
    }
    _out
      ..writeln('];')
      ..writeln();
  }

  // Events -------------------------------------------------------------------

  void _emitEvents() {
    final events = source.events;
    String constName(EventSpecDef e) => _snake(e.field).toUpperCase();
    String variant(EventSpecDef e) => _pascal(e.field);

    _out
      ..writeln('/// The event names, for `events.subscribe`.')
      ..writeln('pub mod events {');
    for (final event in events) {
      _docs(event.docs, '    ');
      _out.writeln(
        '    pub const ${constName(event)}: &str = ${_str(event.name)};',
      );
    }
    _out
      ..writeln('}')
      ..writeln()
      ..writeln(
        '/// Every event, with its payload DTO by name and whether it is '
        'scoped.',
      )
      ..writeln('pub const EVENTS: &[EventSpec] = &[');
    for (final event in events) {
      _out
        ..writeln('    EventSpec {')
        ..writeln('        name: ${_str(event.name)},')
        ..writeln('        payload: ${_option(event.payload)},')
        ..writeln('        scoped: ${event.scoped},')
        ..writeln('    },');
    }
    _out
      ..writeln('];')
      ..writeln()
      ..writeln(
        '/// An event the daemon pushed, decoded from its envelope by name.',
      )
      ..writeln('///')
      ..writeln(
        '/// An event without a payload is a unit variant: the window '
        'refetches what',
      )
      ..writeln(
        '/// it names. One this build does not know is `Event::Unknown`.',
      )
      ..writeln('#[derive(Debug, Clone, PartialEq)]')
      ..writeln('pub enum Event {');
    for (final event in events) {
      _docs(<String>[
        ...event.docs,
        if (event.docs.isNotEmpty) '',
        '`${event.name}`${event.scoped ? ', scoped' : ''}.',
      ], '    ');
      final payload = event.payload;
      _out.writeln(
        payload == null
            ? '    ${variant(event)},'
            : '    ${variant(event)}(${_handWritten[payload] ?? payload}),',
      );
    }
    _out
      ..writeln(
        '    /// An event this build does not know, from a newer daemon, kept '
        'as it came.',
      )
      ..writeln('    Unknown {')
      ..writeln('        name: String,')
      ..writeln('        payload: serde_json::Value,')
      ..writeln('    },')
      ..writeln('}')
      ..writeln()
      ..writeln('impl Event {')
      ..writeln('    /// Decodes `payload` as the event called `name`.')
      ..writeln('    ///')
      ..writeln(
        '    /// A name this build does not know is `Event::Unknown`; a known '
        'one whose',
      )
      ..writeln(
        '    /// payload does not fit its DTO is an error. An event without a '
        'payload',
      )
      ..writeln('    /// ignores whatever it carries.')
      ..writeln(
        '    pub fn decode(name: &str, payload: serde_json::Value) -> '
        'serde_json::Result<Self> {',
      )
      ..writeln('        Ok(match name {');
    for (final event in events) {
      _out.writeln(
        event.payload == null
            ? '            events::${constName(event)} => '
                  'Self::${variant(event)},'
            : '            events::${constName(event)} => '
                  'Self::${variant(event)}(serde_json::from_value(payload)?),',
      );
    }
    _out
      ..writeln('            _ => Self::Unknown {')
      ..writeln('                name: name.to_owned(),')
      ..writeln('                payload,')
      ..writeln('            },')
      ..writeln('        })')
      ..writeln('    }')
      ..writeln()
      ..writeln("    /// The event's name, as the envelope carries it.")
      ..writeln('    pub fn name(&self) -> &str {')
      ..writeln('        match self {');
    for (final event in events) {
      final pattern = event.payload == null ? '' : '(_)';
      _out.writeln(
        '            Self::${variant(event)}$pattern => '
        'events::${constName(event)},',
      );
    }
    _out
      ..writeln('            Self::Unknown { name, .. } => name,')
      ..writeln('        }')
      ..writeln('    }')
      ..writeln()
      ..writeln('    /// The payload as JSON: `{}` for an event without one.')
      ..writeln(
        '    pub fn payload(&self) -> serde_json::Result<serde_json::Value> {',
      )
      ..writeln('        match self {');
    for (final event in events.where((e) => e.payload != null)) {
      _out.writeln(
        '            Self::${variant(event)}(payload) => '
        'serde_json::to_value(payload),',
      );
    }
    final unit = events.where((e) => e.payload == null).toList();
    if (unit.isNotEmpty) {
      _out.writeln(
        '            ${unit.map((e) => 'Self::${variant(e)}').join(' | ')} => '
        'Ok(serde_json::Value::Object(serde_json::Map::new())),',
      );
    }
    _out
      ..writeln(
        '            Self::Unknown { payload, .. } => Ok(payload.clone()),',
      )
      ..writeln('        }')
      ..writeln('    }')
      ..writeln()
      ..writeln(
        '    /// Whether the event is published with a scope (`false` for an '
        'unknown one).',
      )
      ..writeln('    pub fn is_scoped(&self) -> bool {')
      ..writeln('        let name = self.name();')
      ..writeln(
        '        EVENTS.iter().any(|spec| spec.name == name && spec.scoped)',
      )
      ..writeln('    }')
      ..writeln('}')
      ..writeln();
  }

  // Conformance --------------------------------------------------------------

  void _emitConformance() {
    final names = <String>[for (final dto in source.dtos) dto.name]..sort();
    _out
      ..writeln('/// For the conformance tests: every DTO by its Dart name.')
      ..writeln('#[doc(hidden)]')
      ..writeln('pub mod conformance {')
      ..writeln("    /// Every DTO's name.")
      ..writeln('    pub const TYPE_NAMES: &[&str] = &[');
    for (final name in names) {
      _out.writeln('        ${_str(name)},');
    }
    _out
      ..writeln('    ];')
      ..writeln()
      ..writeln(
        '    /// Decodes `json` as the DTO called `type_name` and encodes it '
        'again;',
      )
      ..writeln('    /// `None` for a name that is not a DTO.')
      ..writeln('    pub fn roundtrip(')
      ..writeln('        type_name: &str,')
      ..writeln('        json: &serde_json::Value,')
      ..writeln('    ) -> Option<serde_json::Result<serde_json::Value>> {')
      ..writeln(
        '        fn roundtrip<T>(json: &serde_json::Value) -> '
        'serde_json::Result<serde_json::Value>',
      )
      ..writeln('        where')
      ..writeln(
        '            T: serde::Serialize + serde::de::DeserializeOwned,',
      )
      ..writeln('        {')
      ..writeln(
        '            serde_json::to_value(serde_json::from_value::<T>('
        'json.clone())?)',
      )
      ..writeln('        }')
      ..writeln()
      ..writeln('        Some(match type_name {');
    for (final name in names) {
      final path = _handWritten[name] ?? 'super::$name';
      _out.writeln('            ${_str(name)} => roundtrip::<$path>(json),');
    }
    _out
      ..writeln('            _ => return None,')
      ..writeln('        })')
      ..writeln('    }')
      ..writeln('}');
  }
}

// ---------------------------------------------------------------------------
// Names and literals
// ---------------------------------------------------------------------------

String _option(String? name) => name == null ? 'None' : 'Some(${_str(name)})';

/// A Rust string literal.
String _str(String value) {
  final buffer = StringBuffer('"');
  for (final rune in value.runes) {
    buffer.write(switch (rune) {
      0x5C => r'\\',
      0x22 => r'\"',
      0x0A => r'\n',
      0x0D => r'\r',
      0x09 => r'\t',
      < 0x20 || 0x7F => '\\u{${rune.toRadixString(16)}}',
      _ => String.fromCharCode(rune),
    });
  }
  return (buffer..write('"')).toString();
}

String _pascal(String name) => name[0].toUpperCase() + name.substring(1);

/// `chatId` -> `chat_id`. A run of capitals is one word (`dataURL` ->
/// `data_url`); digits stay with the word before them.
String _snake(String name) {
  bool isUpper(String c) => c != c.toLowerCase();
  final out = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final c = name[i];
    if (isUpper(c) && i > 0) {
      final afterUpper = isUpper(name[i - 1]);
      final beforeLower =
          i + 1 < name.length &&
          !isUpper(name[i + 1]) &&
          name[i + 1] != name[i + 1].toUpperCase();
      if (!afterUpper || beforeLower) out.write('_');
    }
    out.write(c.toLowerCase());
  }
  return out.toString();
}

/// What serde's `rename_all = "camelCase"` makes of a Rust field name.
String _serdeCamel(String ident) {
  final field = ident.startsWith('r#') ? ident.substring(2) : ident;
  final pascal = StringBuffer();
  var capitalize = true;
  for (final c in field.split('')) {
    if (c == '_') {
      capitalize = true;
    } else if (capitalize) {
      pascal.write(c.toUpperCase());
      capitalize = false;
    } else {
      pascal.write(c);
    }
  }
  final text = pascal.toString();
  return text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);
}

String _fieldIdent(String dartName) {
  final snake = _snake(dartName);
  if (_unrawable.contains(snake)) return '${snake}_';
  return _rustKeywords.contains(snake) ? 'r#$snake' : snake;
}

// ---------------------------------------------------------------------------
// rustfmt
// ---------------------------------------------------------------------------

Future<String> _rustfmt(String code, Directory desktop) async {
  final Process process;
  try {
    // From desktop/, so rustup picks the pinned toolchain and rustfmt the
    // workspace's own settings.
    process = await Process.start('rustfmt', <String>[
      '--edition',
      '2024',
      '--config-path',
      'rustfmt.toml',
    ], workingDirectory: desktop.path);
  } on ProcessException catch (error) {
    throw GeneratorError(
      'rustfmt not found ($error). Put the Rust toolchain on PATH; '
      'desktop/rust-toolchain.toml pins it.',
    );
  }
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(code);
  await process.stdin.close();
  final status = await process.exitCode;
  if (status != 0) {
    throw GeneratorError('rustfmt failed ($status):\n${await err}');
  }
  return out;
}

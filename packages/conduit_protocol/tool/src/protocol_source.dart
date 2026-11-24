// The protocol as this package declares it: its DTOs, enums, constants and
// method and event tables, read from lib/src with package:analyzer, for the
// generators that write it out in another language.
//
// It reads the freezed declarations as written, not build_runner's output,
// so it needs no codegen and sees the doc comments. It understands the
// shapes this package uses and fails loudly on anything else, rather than
// guessing at a type.
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

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
  String toString() => message;
}

/// Everything the generator needs from `lib/src`, in a stable order: files
/// by name, declarations as written.
final class ProtocolSource {
  ProtocolSource._(Set<String> handWritten)
    : handWritten = Set.unmodifiable(handWritten);

  /// [handWritten]: type names a generator writes by hand in its own
  /// language; [isType] accepts them as types whether or not this source
  /// declares them.
  factory ProtocolSource.read(
    Directory dir, {
    Set<String> handWritten = const <String>{},
  }) {
    final source = ProtocolSource._(handWritten);
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

  final Set<String> handWritten;
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

  /// Follows a constant reference to its value: `kDefaultUiFontSize`,
  /// `Capabilities.none`. Enum values are left alone.
  Expression resolve(Expression node) {
    for (var depth = 0; depth < 16; depth++) {
      final next = switch (node) {
        SimpleIdentifier(:final name) => topConsts[name],
        PrefixedIdentifier(:final prefix, :final identifier)
            when enumDef(prefix.name) == null =>
          staticConsts['${prefix.name}.${identifier.name}'],
        _ => null,
      };
      if (next == null) return node;
      node = next;
    }
    throw GeneratorError('constant cycle at $node');
  }

  Dto? dto(String name) => dtos.where((d) => d.name == name).firstOrNull;
  EnumDef? enumDef(String name) =>
      enums.where((e) => e.name == name).firstOrNull;

  bool isType(String name) =>
      dto(name) != null ||
      enumDef(name) != null ||
      handWritten.contains(name);

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
        'snake' => snakeCase(value),
        'screamingSnake' => snakeCase(value).toUpperCase(),
        'kebab' => snakeCase(value).replaceAll('_', '-'),
        'pascal' => pascalCase(value),
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
/// The doc comment's lines as the Dart source writes them, without the
/// `///` and one space after it.
List<String> _docs(Comment? comment) {
  if (comment == null) return const <String>[];
  final lines = <String>[];
  for (final token in comment.tokens) {
    final lexeme = token.lexeme;
    if (!lexeme.startsWith('///')) {
      throw GeneratorError('unsupported doc comment `$lexeme`');
    }
    var line = lexeme.substring(3);
    if (line.startsWith(' ')) line = line.substring(1);
    lines.add(line.trimRight());
  }
  return lines;
}

String pascalCase(String name) => name[0].toUpperCase() + name.substring(1);

/// `chatId` -> `chat_id`. A run of capitals is one word (`dataURL` ->
/// `data_url`); digits stay with the word before them.
String snakeCase(String name) {
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

/// The class [node] constructs with its unnamed constructor, `Foo()` or
/// `const Foo()`; null for anything else.
String? constructedType(Expression node) => switch (node) {
  MethodInvocation(:final target, :final methodName) when target == null =>
    methodName.name,
  InstanceCreationExpression(:final constructorName)
      when constructorName.name == null =>
    constructorName.type.name.lexeme,
  _ => null,
};

/// The arguments [node] constructs with; null when it constructs nothing.
NodeList<Argument>? constructorArguments(Expression node) => switch (node) {
  MethodInvocation(:final argumentList) => argumentList.arguments,
  InstanceCreationExpression(:final argumentList) => argumentList.arguments,
  _ => null,
};

// Copyright (c) 2014, Alexandre Ardhuin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

library zengen.transformer;

import 'dart:async' show Future, Completer;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:barback/barback.dart';
import 'package:code_transformers/resolver.dart';

import 'package:zengen/zengen.dart';

final MODIFIERS = <ContentModifier>[//
  new ToStringAppender(), //
  new EqualsAndHashCodeAppender(), //
  new DelegateAppender(), //
];

abstract class ContentModifier {
  List<Transformation> accept(CompilationUnitElement unitElement);
}

class ZengenTransformer extends TransformerGroup {
  ZengenTransformer.asPlugin() : this._(new ModifierTransformer());
  ZengenTransformer._(ModifierTransformer mt) : super(new Iterable.generate(
      1000, (_) => [mt]));
}

class ModifierTransformer extends Transformer {
  Resolvers resolvers = new Resolvers(dartSdkDirectory);
  List<AssetId> unmodified = [];

  Map<AssetId, String> contentsPending = {};

  ModifierTransformer();

  String get allowedExtensions => ".dart";

  Future apply(Transform transform) {
    final id = transform.primaryInput.id;
    if (unmodified.contains(id)) return new Future.value();
    if (contentsPending.containsKey(id)) {
      transform.addOutput(new Asset.fromString(id, contentsPending.remove(id)));
      return new Future.value();
    }
    return resolvers.get(transform).then((resolver) {
      return new Future(() => applyResolver(transform, resolver)).whenComplete(
          () => resolver.release());
    });
  }

  applyResolver(Transform transform, Resolver resolver) {
    final assetId = transform.primaryInput.id;
    final lib = resolver.getLibrary(assetId);

    if (isPart(lib)) return;

    for (final unit in lib.units) {
      final id = unit.source.assetId;
      final transaction = resolver.createTextEditTransaction(unit);
      traverseModifiers(unit, (List<Transformation> transformations) {
        for (final t in transformations) {
          transaction.edit(t.begin, t.end, t.content);
        }
      });
      if (transaction.hasEdits) {
        final np = transaction.commit();
        np.build('');
        final newContent = np.text;
        transform.logger.fine("new content for $id : \n$newContent", asset: id);
        if (id == assetId) {
          transform.addOutput(new Asset.fromString(id, newContent));
        } else {
          contentsPending[id] = newContent;
        }
      } else {
        unmodified.add(id);
      }
    }
  }

  bool isPart(LibraryElement lib) => lib.unit.directives.any((d) => d is
      PartOfDirective);
}


void traverseModifiers(CompilationUnitElement
    unit, onTransformations(List<Transformation> transformations)) {
  bool modifications = true;
  while (modifications) {
    modifications = false;
    for (final modifier in MODIFIERS) {
      final transformations = modifier.accept(unit);
      if (transformations.isNotEmpty) {
        onTransformations(transformations);
        modifications = true;
        return;
      }
    }
  }
}

String applyTransformations(String content, List<Transformation>
    transformations) {
  int padding = 0;
  for (final t in transformations) {
    content = content.substring(0, t.begin + padding) + t.content +
        content.substring(t.end + padding);
    padding += t.content.length - (t.end - t.begin);
  }
  return content;
}

class Transformation {
  final int begin, end;
  final String content;
  Transformation(this.begin, this.end, this.content);
  Transformation.insertion(int index, this.content)
      : begin = index,
        end = index;
  Transformation.deletation(this.begin, this.end) : content = '';
}

class ToStringAppender implements ContentModifier {
  @override
  List<Transformation> accept(CompilationUnitElement unitElement) {
    final transformations = [];
    unitElement.unit.declarations.where((d) => d is ClassDeclaration).where(
        (ClassDeclaration c) => getAnnotations(c, 'ToString').isNotEmpty).forEach(
        (ClassDeclaration clazz) {
      final annotation = getToString(clazz);
      final callSuper = annotation.callSuper == true;
      final exclude = annotation.exclude == null ? [] : annotation.exclude;
      final fieldNames = getFieldNames(clazz).where((f) => !exclude.contains(f)
          );

      final toString = '@generated @override String toString() => '
          '"${clazz.name.name}(' + //
      (callSuper ? 'super=\${super.toString()}' : '') + //
      (callSuper && fieldNames.isNotEmpty ? ', ' : '') + //
      fieldNames.map((f) => '$f=\$$f').join(', ') + ')";';

      final index = clazz.end - 1;
      if (!isMethodDefined(clazz, 'toString')) {
        transformations.add(new Transformation.insertion(index, '  $toString\n')
            );
      }
    });
    return transformations;
  }

  ToString getToString(ClassDeclaration clazz) {
    final Annotation annotation = getAnnotations(clazz, 'ToString').first;

    if (annotation == null) return null;

    bool callSuper = null;
    List<Symbol> exclude = null;

    final NamedExpression callSuperPart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'callSuper', orElse: () => null);
    if (callSuperPart != null) {
      callSuper = (callSuperPart.expression as BooleanLiteral).value;
    }

    final NamedExpression excludePart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'exclude', orElse: () => null);
    if (excludePart != null) {
      exclude = (excludePart.expression as ListLiteral).elements.map(
          (SymbolLiteral sl) => sl.toString().substring(sl.poundSign.length)).toList();
    }

    return new ToString(callSuper: callSuper, exclude: exclude);
  }
}

class EqualsAndHashCodeAppender implements ContentModifier {
  @override
  List<Transformation> accept(CompilationUnitElement unitElement) {
    final transformations = [];
    unitElement.unit.declarations.where((d) => d is ClassDeclaration).where(
        (ClassDeclaration c) => getAnnotations(c, 'EqualsAndHashCode').isNotEmpty
        ).forEach((ClassDeclaration clazz) {
      final annotation = getEqualsAndHashCode(clazz);
      final callSuper = annotation.callSuper == true;
      final exclude = annotation.exclude == null ? [] : annotation.exclude;
      final fieldNames = getFieldNames(clazz).where((f) => !exclude.contains(f)
          );

      final hashCodeValues = fieldNames.toList();
      if (callSuper) hashCodeValues.insert(0, 'super.hashCode');
      final hashCode = '@generated @override int get hashCode => '
          'hashObjects([' + hashCodeValues.join(', ') + ']);';

      final equals = '@generated @override bool operator ==(o) => '
          'o is ${clazz.name.name}' + (callSuper ? ' && super == o' : '') +
          fieldNames.map((f) => ' && o.$f == $f').join() + ';';

      final index = clazz.end - 1;
      if (!isMethodDefined(clazz, 'hashCode')) {
        transformations.add(new Transformation.insertion(index, '  $hashCode\n')
            );
      }
      if (!isMethodDefined(clazz, '==')) {
        transformations.add(new Transformation.insertion(index, '  $equals\n'));
      }
    });
    return transformations;
  }

  EqualsAndHashCode getEqualsAndHashCode(ClassDeclaration clazz) {
    final Annotation annotation = getAnnotations(clazz, 'EqualsAndHashCode'
        ).first;

    if (annotation == null) return null;

    bool callSuper = null;
    List<Symbol> exclude = null;

    final NamedExpression callSuperPart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'callSuper', orElse: () => null);
    if (callSuperPart != null) {
      callSuper = (callSuperPart.expression as BooleanLiteral).value;
    }

    final NamedExpression excludePart =
        annotation.arguments.arguments.firstWhere((e) => e is NamedExpression &&
        e.name.label.name == 'exclude', orElse: () => null);
    if (excludePart != null) {
      exclude = (excludePart.expression as ListLiteral).elements.map(
          (SymbolLiteral sl) => sl.toString().substring(sl.poundSign.length)).toList();
    }

    return new EqualsAndHashCode(callSuper: callSuper, exclude: exclude);
  }
}

class DelegateAppender extends GeneralizingAstVisitor implements ContentModifier
    {
  final transformations = [];

  @override
  List<Transformation> accept(CompilationUnitElement unitElement) {
    transformations.clear();
    unitElement.unit.visitChildren(this);
    return transformations;
  }

  @override
  visitFieldDeclaration(FieldDeclaration node) {
    final delegates = getAnnotations(node, 'Delegate');
    final ClassDeclaration clazz = node.parent;
    final index = node.parent.end - 1;
    for (final delegate in delegates) {
      final excludes = getExcludes(delegate);
      final SimpleIdentifier template = delegate.arguments.arguments.first;
      final ClassElement templateElement = template.staticElement;
      for (final method in templateElement.methods) {
        if (isMemberAlreadyDefined(clazz, method.displayName)) {
          continue;
        }
        if (excludes.contains(method.displayName)) {
          continue;
        }

        final requiredParameters = method.parameters.where((p) =>
            p.parameterKind == ParameterKind.REQUIRED);
        String parametersDeclaration = requiredParameters.join(', ');
        String parametersCall = requiredParameters.map((e) => e.name).join(', '
            );

        final optionalPositionalParameters = method.parameters.where((p) =>
            p.parameterKind == ParameterKind.POSITIONAL);
        if (optionalPositionalParameters.isNotEmpty) {
          if (requiredParameters.isNotEmpty) {
            parametersDeclaration += ', ';
            parametersCall += ', ';
          }
          parametersDeclaration += '[';
          parametersDeclaration += optionalPositionalParameters.map((e) {
            final s = e.toString();
            return s.substring(1, s.length - 1);
          }).join(', ');
          parametersDeclaration += ']';
          parametersCall += optionalPositionalParameters.map((e) => e.name
              ).join(', ');
        }

        final optionalNamedParameters = method.parameters.where((p) =>
            p.parameterKind == ParameterKind.NAMED);
        if (optionalNamedParameters.isNotEmpty) {
          if (requiredParameters.isNotEmpty) {
            parametersDeclaration += ', ';
            parametersCall += ', ';
          }
          parametersDeclaration += '{';
          parametersDeclaration += optionalNamedParameters.map((e) {
            final s = e.toString();
            return s.substring(1, s.length - 1);
          }).join(', ');
          parametersDeclaration += '}';
          parametersCall += optionalNamedParameters.map((e) =>
              '${e.name}: ${e.name}').join(', ');
        }

        final returnType = method.returnType;
        String methodSignature =
            '${method.displayName}($parametersDeclaration)';
        String delegateCall =
            '${node.fields.variables.first.name.name}.${method.displayName}($parametersCall)';

        String code = '@generated ';
        if (returnType.isVoid) {
          code += '$returnType $methodSignature { $delegateCall; }';
        } else {
          code += '$returnType $methodSignature => $delegateCall;';
        }
        transformations.add(new Transformation.insertion(index, '  $code\n'));
      }
    }
  }
  List<String> getExcludes(Annotation delegate) {
    final NamedExpression excludePart = delegate.arguments.arguments.firstWhere(
        (e) => e is NamedExpression && e.name.label.name == 'exclude', orElse: () =>
        null);
    if (excludePart != null) {
      return (excludePart.expression as ListLiteral).elements.map((SymbolLiteral
          sl) => sl.toString().substring(sl.poundSign.length)).toList();
    }
    return [];
  }
}

isMemberAlreadyDefined(ClassDeclaration clazz, String name) =>
    clazz.members.any((m) => (m is MethodDeclaration && m.name.name == name) || (m
    is FieldDeclaration && m.fields.variables.any((f) => f.name.name == name)) || (m
    is ConstructorDeclaration && m.name.name == name));

Iterable<String> getFieldNames(ClassDeclaration clazz) => clazz.members.where(
    (m) => m is FieldDeclaration && !m.isStatic).expand((FieldDeclaration f) =>
    f.fields.variables.map((v) => v.name.name));

const _LIBRARY_NAME = 'zengen';

Iterable<Annotation> getAnnotations(Declaration declaration, String name) =>
    declaration.metadata.where((m) => m.element.library.name == _LIBRARY_NAME &&
    m.element is ConstructorElement && m.element.enclosingElement.name == name);

bool isMethodDefined(ClassDeclaration clazz, String methodName) =>
    clazz.members.any((m) => m is MethodDeclaration && m.name.name == methodName);

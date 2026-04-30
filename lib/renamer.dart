import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'package:analyzer/dart/ast/token.dart';

import 'rules_parser.dart';

class _Edit {
  final int offset;
  final int length;
  final String replacement;

  _Edit(this.offset, this.length, this.replacement);
}

class RenamerVisitor extends RecursiveAstVisitor<void> {
  final Map<int, _Edit> _editsMap = {};
  final String projectRoot;
  final String packageName;
  final ObfuscatorRules rules;
  final Map<String, String> globalNameMap;
  final Set<String> reservedWords = {
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external', 'factory', 'false', 'final', 'finally', 'for', 'Function', 'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow', 'return', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
    'main', 'build', 'initState', 'dispose', 'didChangeDependencies', 'didUpdateWidget', 'createState', 'copyWith', 'fromJson', 'toJson', 'toString', 'noSuchMethod', 'hashCode', 'runtimeType',
  };

  RenamerVisitor(this.projectRoot, this.packageName, this.rules, this.globalNameMap);

  List<_Edit> get edits {
    final list = _editsMap.values.toList();
    list.sort((a, b) => b.offset.compareTo(a.offset));
    return list;
  }

  String _generateNewName(String oldName, bool isClass) {
    if (globalNameMap.containsKey(oldName)) {
      return globalNameMap[oldName]!;
    }

    if (oldName.startsWith('_')) {
      final newName = '_' + rules.generateObfuscatedName(oldName.substring(1), isClass: isClass);
      globalNameMap[oldName] = newName;
      return newName;
    } else {
      final newName = rules.generateObfuscatedName(oldName, isClass: isClass);
      globalNameMap[oldName] = newName;
      return newName;
    }
  }

  bool _isDefinedInProject(Element element) {
    final identifier = element.library?.identifier;
    if (identifier == null) return false;
    
    // e.g. package:loomi_flutter_client/app/foo.dart
    if (identifier.startsWith('package:$packageName/')) return true;
    
    // Local files or file:// paths
    if (identifier.startsWith('file://')) {
      return p.isWithin(projectRoot, identifier.replaceFirst('file://', ''));
    }
    if (p.isAbsolute(identifier)) {
      return p.isWithin(projectRoot, identifier);
    }
    
    // Relative path, probably local project
    if (!identifier.startsWith('dart:') && !identifier.startsWith('package:')) {
      return true;
    }
    
    return false;
  }

  bool _shouldRename(String name, Element element) {
    if (name.length <= 2) {
      return false;
    }
    if (reservedWords.contains(name)) {
      return false;
    }
    // Do not rename RealmModel classes since they are used by code generators
    if (name.endsWith('RealmModel')) {
      return false;
    }
    // Do not rename standard Flutter parameters like 'key'
    if (name == 'key') {
      return false;
    }
    // DO NOT rename named parameters in constructors or method calls since Flutter framework heavily relies on them
    if (element.kind.name == 'PARAMETER') {
      try {
        dynamic d = element;
        if (d.isNamed == true && !name.startsWith('_')) {
          return false;
        }
      } catch (_) {}
    }
    
    // Only rename specific public classes/types if they match certain patterns, 
    // to avoid breaking Flutter framework and pub packages.
    // For example, we want to rename *Controller, *View, *Binding, *Widget, etc.
    // Otherwise, default to only renaming private variables (starting with _)
    if (!name.startsWith('_')) {
      bool isAllowedPublicName = false;
      if (element is InterfaceElement || element is ExtensionElement || element is TypeAliasElement || element is ClassElement) {
        if (name.endsWith('Controller') || 
            name.endsWith('View') || 
            name.endsWith('Binding') || 
            name.endsWith('Widget') ||
            name.endsWith('Page') ||
            name.endsWith('State') ||
            name.endsWith('Model') ||
            name.endsWith('Provider')) {
          isAllowedPublicName = true;
        }
      }
      if (!isAllowedPublicName) {
        return false;
      }
    }
    if (!_isDefinedInProject(element)) {
      return false;
    }

    // Do not rename if the element is defined in a kept directory or generated file
    final identifier = element.library?.identifier;
    if (identifier != null) {
      String? relativePath;
      if (identifier.startsWith('package:$packageName/')) {
        relativePath = identifier.replaceFirst('package:$packageName/', 'lib/');
      } else if (identifier.startsWith('package:')) {
        final parts = identifier.substring(8).split('/');
        final pkg = parts[0];
        relativePath = pkg + '/lib/' + parts.sublist(1).join('/');
      } else if (identifier.startsWith('file://')) {
        final absPath = p.normalize(identifier.replaceFirst('file://', ''));
        relativePath = p.relative(absPath, from: projectRoot);
      } else if (p.isAbsolute(identifier)) {
        relativePath = p.relative(identifier, from: projectRoot);
      }

      if (relativePath != null) {
        if (rules.isKeptFile(relativePath)) {
          return false;
        }
        for (final dir in rules.keptDirectories) {
          if (p.isWithin(dir, relativePath) || relativePath == dir || relativePath.startsWith(dir)) {
            return false;
          }
        }
      }
    }

    if (element is ExecutableElement) {
      if (_overridesExternal(element)) {
        return false;
      }
    }

    return true;
  }

  bool _overridesExternal(ExecutableElement element) {
    if (element is MethodElement) {
      final enclosing = element.enclosingElement;
      if (enclosing is InterfaceElement) {
        // Check supertypes
        for (var supertype in enclosing.allSupertypes) {
          final name = element.name;
          if (name == null) continue;
          final baseMethod = supertype.getMethod(name);
          if (baseMethod != null && !_isDefinedInProject(baseMethod)) {
            return true;
          }
        }
      }
    } else if (element is PropertyAccessorElement) {
      final enclosing = element.enclosingElement;
      if (enclosing is InterfaceElement) {
        for (var supertype in enclosing.allSupertypes) {
          final name = element.name?.replaceAll('=', '');
          if (name == null) continue;
          final baseGetter = supertype.getGetter(name);
          final baseSetter = supertype.getSetter(name);
          if ((baseGetter != null && !_isDefinedInProject(baseGetter)) ||
              (baseSetter != null && !_isDefinedInProject(baseSetter))) {
            return true;
          }
        }
      }
    }
    return false;
  }

  void _renameDeclarationName(AstNode node) {
    dynamic d = node;
    Token? nameToken;
    try {
      try {
        nameToken = d.name2;
      } catch (_) {
        try {
          nameToken = d.namePart?.typeName;
        } catch (_) {
          try {
            var n = d.name;
            if (n is Token) {
              nameToken = n;
            } else if (n is Identifier) {
              nameToken = n.beginToken;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    if (nameToken != null) {
      Element? element;
      try {
        element = d.declaredElement;
      } catch (_) {
        try {
          element = d.declaredFragment?.element;
        } catch (_) {
          try {
            element = d.element;
          } catch (_) {}
        }
      }

      if (element != null && _shouldRename(nameToken.lexeme, element)) {
        final isClass = element is InterfaceElement || element is TypeAliasElement || element is ExtensionElement;
        final newName = _generateNewName(nameToken.lexeme, isClass);
        _editsMap[nameToken.offset] = _Edit(nameToken.offset, nameToken.length, newName);
      }
    }
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _renameDeclarationName(node);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _renameDeclarationName(node);
    super.visitClassDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _renameDeclarationName(node);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _renameDeclarationName(node);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (var variable in node.fields.variables) {
      _renameDeclarationName(variable);
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _renameDeclarationName(node);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _renameDeclarationName(node);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    _renameDeclarationName(node);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (node.name != null) {
      dynamic d = node;
      Token? nameToken;
      try {
        try {
          nameToken = d.name2;
        } catch (_) {
          var n = d.name;
          if (n is Token) {
            nameToken = n;
          } else if (n is Identifier) {
            nameToken = n.beginToken;
          }
        }
      } catch (_) {}

      if (nameToken != null) {
        Element? element;
        try {
          element = d.declaredElement;
        } catch (_) {
          try {
            element = d.declaredFragment?.element;
          } catch (_) {}
        }
        if (element != null && _shouldRename(nameToken.lexeme, element)) {
          final newName = _generateNewName(nameToken.lexeme, false);
          _editsMap[nameToken.offset] = _Edit(nameToken.offset, nameToken.length, newName);
        }
      }
    }
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    _renameDeclarationName(node);
    super.visitSimpleFormalParameter(node);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    _renameDeclarationName(node);
    super.visitFieldFormalParameter(node);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    _renameDeclarationName(node);
    super.visitDefaultFormalParameter(node);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    dynamic d = node;
    Token? nameToken;
    try {
      try {
        nameToken = d.name2;
      } catch (_) {
        var n = d.name;
        if (n is Token) {
          nameToken = n;
        } else if (n is Identifier) {
          nameToken = n.beginToken;
        }
      }
    } catch (_) {}

    if (nameToken != null) {
      Element? element;
      try {
        element = d.declaredElement;
      } catch (_) {
        try {
          element = d.declaredFragment?.element;
        } catch (_) {}
      }

      if (element != null && _shouldRename(nameToken.lexeme, element)) {
        final isClass = element is InterfaceElement || element is TypeAliasElement || element is ExtensionElement;
        final newName = _generateNewName(nameToken.lexeme, isClass);
        _editsMap[nameToken.offset] = _Edit(nameToken.offset, nameToken.length, newName);
      }
    }
    super.visitSuperFormalParameter(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final name = node.name;
    Element? element;
    try {
      dynamic d = node;
      element = d.writeOrReadElement ?? d.element;
    } catch (_) {
      element = node.element;
    }

    if (element == null) {
      AstNode? current = node;
      while (current != null) {
        if (current is AssignmentExpression) {
          try {
            dynamic p = current;
            element = p.writeElement ?? p.readElement;
          } catch (_) {}
          break;
        } else if (current is PostfixExpression) {
          try {
            dynamic p = current;
            element = p.writeElement ?? p.readElement;
          } catch (_) {}
          break;
        } else if (current is PrefixExpression) {
          try {
            dynamic p = current;
            element = p.writeElement ?? p.readElement;
          } catch (_) {}
          break;
        }
        if (current.parent is ExpressionStatement || current.parent is Block) break;
        current = current.parent;
      }
    }

    if (element != null && _shouldRename(name, element)) {
      final isClass = element is InterfaceElement || element is TypeAliasElement || element is ExtensionElement;
      final newName = _generateNewName(name, isClass);
      _editsMap[node.offset] = _Edit(node.offset, node.length, newName);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    // If this is in an extends clause, check if parent class was already renamed
    if (node.parent is ExtendsClause) {
      dynamic d = node;
      Token? nameToken;
      try {
        nameToken = d.name2;
      } catch (_) {
        try {
          var n = d.name;
          if (n is Token) {
            nameToken = n;
          } else if (n is Identifier) {
            nameToken = n.beginToken;
          }
        } catch (_) {}
      }
      
      if (nameToken != null) {
        final name = nameToken.lexeme;
        
        // Check globalNameMap first - if parent was already renamed, use that name
        if (globalNameMap.containsKey(name)) {
          final newName = globalNameMap[name]!;
          _editsMap[nameToken.offset] = _Edit(nameToken.offset, nameToken.length, newName);
          super.visitNamedType(node);
          return;
        }
        
        // Otherwise try to rename it based on its own declaration
        final element = node.element;
        if (element != null && _shouldRename(name, element)) {
          final isClass = element is InterfaceElement || element is TypeAliasElement || element is ExtensionElement;
          final newName = _generateNewName(name, isClass);
          _editsMap[nameToken.offset] = _Edit(nameToken.offset, nameToken.length, newName);
        }
      }
      super.visitNamedType(node);
      return;
    }
    
    dynamic d = node;
    Token? nameToken;
    try {
      nameToken = d.name2;
    } catch (_) {
      try {
        var n = d.name;
        if (n is Token) {
          nameToken = n;
        } else if (n is Identifier) {
          nameToken = n.beginToken;
        }
      } catch (_) {}
    }

    if (nameToken != null) {
      final name = nameToken.lexeme;
      final element = node.element;
      if (element != null && _shouldRename(name, element)) {
        final isClass = element is InterfaceElement || element is TypeAliasElement || element is ExtensionElement;
        final newName = _generateNewName(name, isClass);
        _editsMap[nameToken.offset] = _Edit(nameToken.offset, nameToken.length, newName);
      }
    }
    super.visitNamedType(node);
  }
  
  // also rename string interpolation like $_var or ${_var}
  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    final expr = node.expression;
    if (expr is SimpleIdentifier) {
      final name = expr.name;
      Element? element;
      try {
        dynamic d = expr;
        element = d.writeOrReadElement ?? d.element;
      } catch (_) {
        element = expr.element;
      }
      if (element != null && _shouldRename(name, element)) {
        final newName = _generateNewName(name, false);
        _editsMap[expr.offset] = _Edit(expr.offset, expr.length, newName);
      }
    }
    super.visitInterpolationExpression(node);
  }
}

class DartRenamer {
  final String projectRoot;
  final String packageName;
  final ObfuscatorRules rules;
  late AnalysisContextCollection collection;
  final Map<String, String> globalNameMap = {};

  DartRenamer(this.projectRoot, this.packageName, this.rules);

  Future<void> run(List<String> dartFiles) async {
    print('Initializing AnalysisContextCollection for ${dartFiles.length} files...');
    collection = AnalysisContextCollection(
      includedPaths: [p.normalize(p.absolute(projectRoot))],
      excludedPaths: [
        p.normalize(p.absolute(p.join(projectRoot, 'build'))),
        p.normalize(p.absolute(p.join(projectRoot, '.dart_tool'))),
        p.normalize(p.absolute(p.join(projectRoot, '.pub-cache'))),
        p.normalize(p.absolute(p.join(projectRoot, 'ios'))),
        p.normalize(p.absolute(p.join(projectRoot, 'android'))),
        p.normalize(p.absolute(p.join(projectRoot, 'macos'))),
        p.normalize(p.absolute(p.join(projectRoot, 'windows'))),
        p.normalize(p.absolute(p.join(projectRoot, 'linux'))),
      ],
    );

    // Process files sequentially or in batches.
    int i = 0;
    for (var file in dartFiles) {
      i++;
      final absPath = p.normalize(p.absolute(file));
      final relativePath = p.relative(absPath, from: projectRoot);
      print('[$i/${dartFiles.length}] Processing: $relativePath');
      
      try {
        final context = collection.contextFor(absPath);
        final result = await context.currentSession.getResolvedUnit(absPath);
        if (result is ResolvedUnitResult) {
          final visitor = RenamerVisitor(projectRoot, packageName, rules, globalNameMap);
          result.unit.accept(visitor);
          
          final edits = visitor.edits;
          if (edits.isNotEmpty) {
            String content = result.content;
            for (final edit in edits) {
              content = content.replaceRange(edit.offset, edit.offset + edit.length, edit.replacement);
            }
            File(absPath).writeAsStringSync(content);
          }
        } else {
          print('  -> Failed to resolve unit');
        }
      } catch (e) {
        print('  -> Error processing file: $e');
      }
    }
  }
}

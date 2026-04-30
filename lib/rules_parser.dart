import 'dart:io';

class ObfuscatorRules {
  final List<String> keepDirs = [];
  final List<String> keepExtends = [];
  final Map<String, List<String>> keepClassMethods = {};
  bool renameFiles = true;

  // For compatibility with renamer.dart calls
  bool isKeptFile(String relativePath) {
    return false; // Can implement specific file exclusion here if needed
  }
  
  List<String> get keptDirectories => keepDirs;

  // Add random string generator for ObfuscatorRules
  final Map<String, String> _generatedNames = {};
  int _counter = 0;

  String generateObfuscatedName(String originalName, {bool isClass = false}) {
    if (_generatedNames.containsKey(originalName)) {
      return _generatedNames[originalName]!;
    }
    
    _counter++;
    // Use a simple generator for now, you can enhance it to be more secure/random
    String newName = isClass ? 'ObfuscatedClass$_counter' : 'obfuscatedVar$_counter';
    _generatedNames[originalName] = newName;
    return newName;
  }

  static ObfuscatorRules parse(String rulesFilePath) {
    final rules = ObfuscatorRules();
    final file = File(rulesFilePath);
    if (!file.existsSync()) {
      print('Warning: rules file not found at $rulesFilePath');
      return rules;
    }

    final lines = file.readAsLinesSync();
    bool insideClassBlock = false;
    String currentClass = '';

    for (var line in lines) {
      line = line.trim();
      // Remove comments
      final commentIdx = line.indexOf('#');
      if (commentIdx != -1) {
        line = line.substring(0, commentIdx).trim();
      }
      if (line.isEmpty) continue;

      if (line.startsWith('-rename-files no')) {
        rules.renameFiles = false;
      } else if (line.startsWith('-keep class')) {
        if (line.contains('extends')) {
          final parts = line.split('extends');
          if (parts.length > 1) {
            final ext = parts[1].trim();
            rules.keepExtends.add(ext);
          }
        } else if (line.endsWith('{')) {
          insideClassBlock = true;
          // Example: -keep class lib/app/modules/.../ChatController {
          final match = RegExp(r'-keep class\s+(.+)\s+\{').firstMatch(line);
          if (match != null) {
            final classPath = match.group(1)!;
            // The classPath might be file/path.dart/ClassName or just ClassName
            final nameParts = classPath.split('/');
            currentClass = nameParts.last;
            rules.keepClassMethods[currentClass] = [];
          }
        } else {
          // -keep class lib/app/config/** { *; }
          // Actually, the original python script handled `** { *; }`
          // Let's check the python implementation.
          final match = RegExp(r'-keep class\s+(.+?)(?:\s*\{\s*\*\s*;\s*\})?$').firstMatch(line);
          if (match != null) {
            var dirPattern = match.group(1)!.trim();
            if (dirPattern.endsWith('/**')) {
              dirPattern = dirPattern.substring(0, dirPattern.length - 3);
            }
            rules.keepDirs.add(dirPattern);
          }
        }
      } else if (insideClassBlock) {
        if (line == '}') {
          insideClassBlock = false;
          currentClass = '';
        } else {
          // e.g., String fansFollowMsg(List<int> contents, int key, bool hasEmoji);
          // Just extract the method name before the parenthesis
          final match = RegExp(r'\s+([A-Za-z0-9_]+)\s*\(').firstMatch(line);
          if (match != null && currentClass.isNotEmpty) {
            rules.keepClassMethods[currentClass]!.add(match.group(1)!);
          }
        }
      }
    }
    return rules;
  }

  bool isDirKept(String filePath) {
    final normalizedPath = filePath.replaceAll('\\', '/');
    for (final dir in keepDirs) {
      if (normalizedPath.startsWith(dir)) {
        return true;
      }
    }
    return false;
  }
  
  List<String> getKeepMethodNames() {
    final names = <String>{};
    for (final methods in keepClassMethods.values) {
      names.addAll(methods);
    }
    return names.toList();
  }
}

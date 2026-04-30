import 'dart:io';
import 'dart:math';

import 'rules_parser.dart';

class JunkInjector {
  final ObfuscatorRules rules;
  final double probability;
  final Random _random = Random();
  
  final List<String> dinoNames = ["triceratops", "velociraptor", "stegosaurus", "spinosaurus"];
  final List<String> birdNames = ["Oriole", "Sparrow", "Starling", "Robin"];

  JunkInjector(this.rules, {this.probability = 0.5});

  String apply(String code, String filePath) {
    if (rules.isDirKept(filePath) || _isGeneratedFile(filePath)) {
      return code;
    }
    
    if (_random.nextDouble() >= probability) {
      return code;
    }
    
    if (_hasLibraryOrPartOf(code)) {
      return code;
    }

    final junkFuncName = dinoNames[_random.nextInt(dinoNames.length)] + birdNames[_random.nextInt(birdNames.length)] + "Calculator";
    final varName = birdNames[_random.nextInt(birdNames.length)].toLowerCase();
    
    final junkTemplate = """
  double $junkFuncName(double val) {
    double $varName = 1.0;
    for (var u = 0; u < 2; u++) {
       $varName *= val;
    }
    return $varName;
  }
""";

    final classEndIdx = _findLastClassEndBrace(code);
    if (classEndIdx != -1) {
      code = code.substring(0, classEndIdx) + junkTemplate + code.substring(classEndIdx);
    }
    
    return code;
  }

  bool _isGeneratedFile(String filePath) {
    final base = filePath.split('/').last;
    if (base.endsWith('.g.dart') || base.endsWith('.freezed.dart') || base.endsWith('.gen.dart') || base.endsWith('.gr.dart') || base.endsWith('.realm.dart')) {
      return true;
    }
    if (base == 'firebase_options.dart') return true;
    if (filePath.contains('/generated/')) return true;
    return false;
  }

  bool _hasLibraryOrPartOf(String code) {
    for (final line in code.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      if (s.startsWith('//')) continue;
      if (s.startsWith('/*')) break;
      if (RegExp(r"^(library|part\s+of)\b").hasMatch(s)) {
        return true;
      }
    }
    return false;
  }

  int _findLastClassEndBrace(String code) {
    int lastClassEnd = -1;
    int braceCount = 0;
    bool inClass = false;
    final lines = code.split('\n');
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      
      if (trimmed.startsWith('class ') || trimmed.startsWith('abstract class ') || 
          trimmed.startsWith('mixin class ') || trimmed.startsWith('class {')) {
        if (!inClass) {
          inClass = true;
        }
      }
      
      if (inClass) {
        for (int j = 0; j < line.length; j++) {
          if (line[j] == '{') {
            braceCount++;
          } else if (line[j] == '}') {
            braceCount--;
            if (braceCount == 0) {
              lastClassEnd = _getGlobalIndex(code, i, j);
              inClass = false;
              break;
            }
          }
        }
      }
    }
    
    return lastClassEnd;
  }
  
  int _getGlobalIndex(String code, int lineNum, int colNum) {
    int idx = 0;
    for (int i = 0; i < lineNum; i++) {
      final nextNewline = code.indexOf('\n', idx);
      if (nextNewline == -1) break;
      idx = nextNewline + 1;
    }
    return idx + colNum;
  }
}

class HeaderPolluter {
  final ObfuscatorRules rules;
  final double probability;
  final Random _random = Random();

  HeaderPolluter(this.rules, {this.probability = 0.5});

  String apply(String code, String filePath) {
    if (rules.isDirKept(filePath) || _isGeneratedFile(filePath)) {
      return code;
    }
    
    if (_random.nextDouble() >= probability) {
      return code;
    }
    
    if (_hasLibraryOrPartOf(code)) {
      return code;
    }

    final bloat = "import 'dart:math' as Math;\n" * 3;
    return bloat + code;
  }

  bool _isGeneratedFile(String filePath) {
    final base = filePath.split('/').last;
    if (base.endsWith('.g.dart') || base.endsWith('.freezed.dart') || base.endsWith('.gen.dart') || base.endsWith('.gr.dart') || base.endsWith('.realm.dart')) {
      return true;
    }
    if (base == 'firebase_options.dart') return true;
    if (filePath.contains('/generated/')) return true;
    return false;
  }

  bool _hasLibraryOrPartOf(String code) {
    for (final line in code.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      if (s.startsWith('//')) continue;
      if (s.startsWith('/*')) break;
      if (RegExp(r"^(library|part\s+of)\b").hasMatch(s)) {
        return true;
      }
    }
    return false;
  }
}

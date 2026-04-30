import 'dart:math';

import 'rules_parser.dart';

class StringEncryptor {
  final ObfuscatorRules rules;
  final Random _random = Random();
  final List<String> dinoNames = ["triceratops", "velociraptor", "stegosaurus", "spinosaurus", "ankylosaurus"];
  final List<String> birdNames = ["Oriole", "Sparrow", "Starling", "Robin", "Finch"];

  StringEncryptor(this.rules);

  String apply(String code, String filePath) {
    if (rules.isDirKept(filePath) || _isGeneratedFile(filePath)) {
      return code;
    }

    final fileXorKey = _random.nextInt(156) + 100; // 100 to 255
    final helperName = dinoNames[_random.nextInt(dinoNames.length)] + birdNames[_random.nextInt(birdNames.length)];

    // 1. Fix implicit string concatenation (only if no + operator is present)
    // Use negative lookbehind to exclude cases like "'foo' + 'bar'" where + already exists
    code = code.replaceAllMapped(
      RegExp(r"((?:r|R)?'[^'\n]*?'|(?:r|R)?\x22[^\n\x22]*?\x22)(\s+)(?!\s*\+)(?=['\x22])"),
      (match) => "${match.group(1)} + ${match.group(2)}"
    );

    // Protect imports
    final importProtected = <String>[];
    code = code.replaceAllMapped(
      RegExp(r"\b(import|export|part(?:\s+of)?)\s+(?:['\x22].*?['\x22]|[\w.]+)(?:(?![;])[\s\S])*?;"),
      (match) {
        importProtected.add(match.group(0)!);
        return "__IMPORT_PLACEHOLDER_${importProtected.length - 1}__";
      }
    );

    int subsCount = 0;

    // Only encrypt class-level field declarations (not method-local assignments)
    // Match patterns like: "String name = 'xxx';" or "final String name = 'xxx';"
    // But NOT: "name = 'xxx';" (inside methods) or "const String name = 'xxx';"
    code = code.replaceAllMapped(
      RegExp(r"""^(\s*)([\w\s<>,\[\]\?]+)\s*=\s*(.*)$""", multiLine: true),
      (assignmentMatch) {
        final leadingSpaces = assignmentMatch.group(1)!;
        final prefix = assignmentMatch.group(2)!;
        final expression = assignmentMatch.group(3)!;
        
        // Skip if prefix contains 'const'
        if (prefix.contains('const ')) {
          return assignmentMatch.group(0)!;
        }
        
        // Skip things like !=, <=, >=, ==
        if (prefix.trim().endsWith('!') || prefix.trim().endsWith('<') || prefix.trim().endsWith('>')) {
          return assignmentMatch.group(0)!;
        }
        
        final cleanExpr = expression.split('//')[0].trim();
        if (!cleanExpr.endsWith(';')) {
          return assignmentMatch.group(0)!;
        }
        
        // Skip if the prefix is a keyword that doesn't make sense for a field declaration
        final keywordsThatAreNotTypes = ['if', 'else', 'for', 'while', 'switch', 'case', 'return', 'break', 'continue', 'throw', 'try', 'catch', 'finally', 'do', 'in', 'is', 'as', 'new', 'class', 'enum', 'extends', 'implements', 'with', 'abstract'];
        final firstWord = prefix.trim().split(' ').first;
        if (keywordsThatAreNotTypes.contains(firstWord)) {
          return assignmentMatch.group(0)!;
        }
        
        // Skip if this looks like a function/constructor definition (ends with ") {" or "})")
        if (cleanExpr.contains(') {') || cleanExpr.contains('})')) {
          return assignmentMatch.group(0)!;
        }
        
        // Only encrypt if it looks like a field declaration:
        // Check if there's a type prefix before the variable name (e.g., "String name =", "final String name =")
        final lineContent = assignmentMatch.group(0)!;
        final hasTypePrefix = RegExp(r'''^\s*(?:final|const|var|late|static|int|String|bool|double|List|Map|Set|Object|dynamic)\s+\w+\s*=''').hasMatch(lineContent);
        
        // If no clear type prefix, don't encrypt (to avoid encrypting method-local variables)
        if (!hasTypePrefix) {
          return assignmentMatch.group(0)!;
        }

        final processedExpr = expression.replaceAllMapped(
          RegExp(r"(^|[^rR])(['\x22])([^'\x22\n\$]{2,})\2"),
          (innerMatch) {
            final before = innerMatch.group(1)!;
            final quote = innerMatch.group(2)!;
            final rawText = innerMatch.group(3)!;
            
            if (rawText.length < 2 || rawText.contains('\$')) {
              return innerMatch.group(0)!;
            }

            final encArr = _encryptString(rawText, fileXorKey);
            encArr.add(0 ^ fileXorKey);
            subsCount++;
            return "$before$helperName($encArr, 0x${fileXorKey.toRadixString(16)}, false)";
          }
        );
        
        // If no actual encryption happened, preserve the original line exactly
        if (processedExpr == expression) {
          return assignmentMatch.group(0)!;
        }
        
        // Trim prefix and add proper spacing around "="
        return leadingSpaces + prefix.trim() + " = " + processedExpr.trim();
      }
    );

    // Restore imports
    for (int i = 0; i < importProtected.length; i++) {
      code = code.replaceAll("__IMPORT_PLACEHOLDER_${i}__", importProtected[i]);
    }

    if (subsCount > 0) {
      if (!code.contains("import 'dart:convert';")) {
        code = "import 'dart:convert';\n" + code;
      }
      code += "\n" + _generateDecryptHelper(helperName);
    }

    return code;
  }

  List<int> _encryptString(String text, int key) {
    return text.codeUnits.map((c) => c ^ key).toList();
  }

  String _generateDecryptHelper(String funcName) {
    return """
String $funcName(List<int> contents, int key, bool hasEmoji) {
   var newList = <int>[];
   for (int i = 0; i < contents.length; i++) {
     var v = contents[i];
     v ^= key;
     v &= 0xff;
     if (v == 0 && i == contents.length - 1) {
       break;
     }
     newList.add(v);
   }
   var result = utf8.decode(newList);
   if (hasEmoji) {
     return result.replaceAllMapped(new RegExp(r"\\\\u([0-9A-F]{4})", caseSensitive: false), (Match m) => String.fromCharCode(int.parse(m[1]!, radix:16)));
   }
   return result;
}
""";
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
}

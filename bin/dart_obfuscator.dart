import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../lib/file_renamer.dart';
import '../lib/rules_parser.dart';
import '../lib/renamer.dart';
import '../lib/encryptor.dart';
import '../lib/injector.dart';

bool isGeneratedFile(String filePath) {
  return filePath.endsWith('.g.dart') || 
         filePath.endsWith('.freezed.dart') || 
         filePath.endsWith('.realm.dart') ||
         filePath.endsWith('.gen.dart');
}

void main(List<String> args) async {
  print('=== Dart Obfuscator (AST-based) ===');
  
  // Always use Directory.current to get the project root because the python script sets cwd to project_root.
  // Actually the python script `dart_obfuscator.py` runs this script via `subprocess.run(cmd, cwd=script_dir)`.
  // So the current directory is `dart_obfuscator/`.
  final projectRoot = p.normalize(p.join(Directory.current.path, '..'));
  
  final rulesFile = p.join(projectRoot, 'dart_obfuscator_rules.pro');
  if (!File(rulesFile).existsSync()) {
    print('Error: rules file not found at $rulesFile');
    exit(1);
  }
  
  final rules = ObfuscatorRules.parse(rulesFile);
  print('Loaded rules from $rulesFile');
  
  final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    print('Error: pubspec.yaml not found in project root.');
    exit(1);
  }
  
  final pubspecContent = pubspecFile.readAsStringSync();
  final yaml = loadYaml(pubspecContent);
  final packageName = yaml['name'] as String?;
  if (packageName == null) {
    print('Error: Could not find package name in pubspec.yaml');
    exit(1);
  }
  
  print('Package name: $packageName');
  
  final dartFiles = <String>[];
  final dir = Directory(projectRoot);
  
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final relativePath = p.relative(entity.path, from: projectRoot);
      if (relativePath.startsWith('.')) continue;
      if (relativePath.startsWith('build/')) continue;
      if (relativePath.contains('.dart_tool/')) continue;
      if (relativePath.contains('/.pub-cache/')) continue;
      
      // Do not obfuscate the obfuscator itself!
      if (relativePath.startsWith('dart_obfuscator/')) continue;
      
      dartFiles.add(entity.path);
    }
  }
  
  print('Found ${dartFiles.length} dart files to process.');
  
  final renamer = DartRenamer(projectRoot, packageName, rules);
  await renamer.run(dartFiles);
  
  print('Applying obfuscation passes (Encryption, Junk Injection)...');
  print('File/Directory renaming will be performed at the end.');
  print('');
  final encryptor = StringEncryptor(rules);
  final junkInjector = JunkInjector(rules);
  final polluter = HeaderPolluter(rules);
  
  int applyCount = 0;
  final int maxWorkers = 5;
  final List<List<String>> chunks = List.generate(maxWorkers, (_) => []);
  for (int i = 0; i < dartFiles.length; i++) {
    chunks[i % maxWorkers].add(dartFiles[i]);
  }

  Future<void> postWorker(int workerId, List<String> files) async {
    for (final path in files) {
      applyCount++;
      final relativePath = p.relative(path, from: projectRoot);
      if (rules.isDirKept(relativePath) || isGeneratedFile(path)) continue;
      
      print('[Worker $workerId] [$applyCount/${dartFiles.length}] Post-processing: $relativePath');
      
      final file = File(path);
      var content = await file.readAsString();
      
      content = encryptor.apply(content, path);
      content = junkInjector.apply(content, path);
      content = polluter.apply(content, path);
      
      await file.writeAsString(content);
    }
  }

  await Future.wait(List.generate(maxWorkers, (i) => postWorker(i + 1, chunks[i])));
  
  print('');
  print('=== Step 2: Renaming files and directories ===');
  ENABLE_FILE_RENAMING = true;
  ENABLE_DIR_RENAMING = false;
  final fileRenamer = FileRenamer(rules);
  fileRenamer.apply(projectRoot);
  ENABLE_FILE_RENAMING = false;
  ENABLE_DIR_RENAMING = true;
  final fileRenamer1 = FileRenamer(rules);
  fileRenamer1.apply(projectRoot);
  
  print('=== Obfuscation completed ===');
}

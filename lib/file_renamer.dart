import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

import 'rules_parser.dart';

// ============================================================
// 配置开关：开启/关闭文件重命名和目录重命名
// ============================================================
bool ENABLE_FILE_RENAMING = false;   // 是否开启文件重命名
bool ENABLE_DIR_RENAMING = false;     // 是否开启目录重命名

// ============================================================
// FileRenamer: Dart 文件和目录混淆器
// 
// 主要功能：
// 1. 文件重命名：将 Dart 文件名混淆为恐龙+鸟类名称
// 2. 目录重命名：将目录名混淆为恐龙+鸟类名称
// 3. 更新所有 import 引用
//
// 流程：
//   Step 1: 收集所有目录和文件信息，建立树结构
//   Step 2: 执行所有重命名（文件和目录）
//   Step 3: 统一更新所有 import 依赖
//
// 数据结构：
//   _DirInfo: 目录信息，包含父目录指针
//   _FileInfo: 文件信息，包含父目录指针和依赖列表
//   DependInfo: 依赖信息，包含文件指针和依赖路径
//
// 保留规则：
//   - import 'package:...' 不重命名（第三方包）
//   - 特定目录保留：app/core/tracing, app/tools/google, app/tools/rtc, app/tools/fb
// ============================================================
class FileRenamer {
  final ObfuscatorRules rules;
  final Random _random = Random();
  
  // 包名（从 pubspec.yaml 读取）
  String _packageName = '';
  
  // 目录 ID 计数器
  int _dirId = 0;
  
  // 已使用的目录名集合
  final Set<String> _usedDirNames = {};
  
  // 恐龙名称列表
  final List<String> dinoNames = [
    "triceratops", "velociraptor", "stegosaurus", "spinosaurus", 
    "ankylosaurus", "pachycephalosaurus", "parasaurolophus", 
    "brachiosaurus", "diplodocus", "allosaurus"
  ];

  // 鸟类名称列表
  final List<String> birdNames = [
    "Oriole", "Sparrow", "Starling", "Robin", "Finch", "Wren", 
    "Swallow", "Nightingale", "Cardinal", "Bluebird"
  ];

  // 已使用的文件名集合（确保唯一性）
  Set<String> _usedFileNames = {};
  
  // 所有目录信息列表（用于重命名）
  final List<_DirInfo> _allDirs = [];
  
  // 所有文件信息列表（用于依赖更新）
  final List<_FileInfo> _allFiles = [];

  FileRenamer(this.rules);

  // ============================================================
  // 生成唯一的混淆文件名（小写）
  // ============================================================
  String _generateUniqueFileName(String originalName) {
    for (int i = 0; i < 100; i++) {
      final dino = dinoNames[_random.nextInt(dinoNames.length)].toLowerCase();
      final bird = birdNames[_random.nextInt(birdNames.length)].toLowerCase();
      final extension = p.extension(originalName);
      final newName = i == 0 ? '$dino$bird$extension' : '$dino$bird$i$extension';
      
      if (!_usedFileNames.contains(newName)) {
        _usedFileNames.add(newName);
        return newName;
      }
    }
    throw Exception('Failed to generate unique file name for $originalName');
  }

  // ============================================================
  // 生成混淆目录名
  // 生成格式：恐龙名前3个字母（小写）+ 自增ID（如 tr1, sp2, st3）
  // ============================================================
  String _generateDirectoryName(String originalName) {
    _dirId++;
    
    // 取恐龙名前3个字母，转为小写
    final dino = dinoNames[_random.nextInt(dinoNames.length)].substring(0, 3).toLowerCase();
    final name = '$dino$_dirId';
    
    // 确保不重复
    if (!_usedDirNames.contains(name)) {
      _usedDirNames.add(name);
      return name;
    }
    
    // 如果重复，尝试其他恐龙名
    for (final d in dinoNames) {
      final tryName = '${d.substring(0, 3).toLowerCase()}$_dirId';
      if (!_usedDirNames.contains(tryName)) {
        _usedDirNames.add(tryName);
        return tryName;
      }
    }
    
    // 再试一次，加个后缀
    return '${name}_${_random.nextInt(100)}';
  }

  // ============================================================
  // 检查名称是否已经混淆
  // ============================================================
  bool _isAlreadyObfuscated(String name) {
    final lower = name.toLowerCase();
    for (final dino in dinoNames) {
      for (final bird in birdNames) {
        if (lower.contains(dino) && lower.contains(bird)) {
          return true;
        }
      }
    }
    return false;
  }

  // ============================================================
  // 检查路径是否需要跳过（保留的目录前缀）
  // ============================================================
  bool _shouldSkipPath(String relativePath) {
    final keptPrefixes = [
      'app/core/tracing',   // 埋点相关
      'app/tools/google',  // Google工具
      'app/tools/rtc',     // RTC工具
      'app/tools/fb'       // Firebase工具
    ];
    for (final prefix in keptPrefixes) {
      if (relativePath == prefix || relativePath.startsWith('$prefix/')) {
        return true;
      }
    }
    return false;
  }

  // ============================================================
  // 从 pubspec.yaml 读取包名
  // ============================================================
  String _readPackageName(String projectRoot) {
    try {
      final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));
      if (!pubspecFile.existsSync()) {
        print('[WARN] pubspec.yaml not found, using default: live');
        return 'live';
      }
      
      final content = pubspecFile.readAsStringSync();
      final match = RegExp(r"^name:\s*(\S+)").firstMatch(content);
      if (match != null) {
        return match.group(1) ?? 'live';
      }
      
      print('[WARN] Could not parse package name, using default: live');
      return 'live';
    } catch (e) {
      print('[WARN] Error reading pubspec.yaml: $e, using default: live');
      return 'live';
    }
  }

  // ============================================================
  // 主入口：执行所有混淆操作
  // ============================================================
  void apply(String projectRoot) {
    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (!libDir.existsSync()) {
      print('lib directory not found, skipping file renaming');
      return;
    }

    // 从 pubspec.yaml 读取包名
    _packageName = _readPackageName(projectRoot);
    print('[CONFIG] Package name: $_packageName');
    print('');

    print('');
    print('=' * 60);
    print('STARTING DART OBFUSCATION PROCESS');
    print('=' * 60);
    print('');
    print('[CONFIG] ENABLE_FILE_RENAMING: $ENABLE_FILE_RENAMING');
    print('[CONFIG] ENABLE_DIR_RENAMING: $ENABLE_DIR_RENAMING');
    print('');

    _usedFileNames = {};
    _allDirs.clear();
    _allFiles.clear();

    // ==================== 第一步：收集所有信息 ====================
    print('[STEP 1] Collecting all directory and file information...');
    print('-' * 60);
    _collectAllInfo(libDir, null);
    print('[SUMMARY] Collected ${_allDirs.length} directories and ${_allFiles.length} files');
    print('');
    
    // 打印所有文件的路径和索引
    print('[FILE_LIST] All collected files (${_allFiles.length} files):');
    for (int i = 0; i < _allFiles.length; i++) {
      print('  [$i] ${_allFiles[i].outputFilePath()}');
    }
    print('');
    
    // ==================== 第二步：收集所有依赖关系 ====================
    print('[STEP 2] Collecting all dependency information...');
    print('-' * 60);
    _collectAllDepends(libDir);
    int totalDepends = 0;
    for (final file in _allFiles) {
      totalDepends += file.newUpdateImports.length;
    }
    print('[SUMMARY] Collected $totalDepends dependencies');
    print('');
    
    // ==================== 第三步：执行所有重命名 ====================
    print('[STEP 2] Executing all renames...');
    print('-' * 60);
    _executeAllRenames(projectRoot);
    print('');
    
    // ==================== 第三步：更新所有依赖 ====================
    print('[STEP 3] Updating all import dependencies...');
    print('-' * 60);
    _updateAllDependencies(projectRoot);
    print('');

    // 保存映射关系
    _saveMappingFile(projectRoot);

    print('=' * 60);
    print('DART OBFUSCATION COMPLETED!');
    print('=' * 60);
    print('');
  }

  // ============================================================
  // 第一步：收集所有目录和文件信息，建立树结构
  // ============================================================
  void _collectAllInfo(Directory current, _DirInfo? parentDir) {
    for (final entity in current.listSync(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        final dirName = p.basename(entity.path);
        final relativePath = entity.path.replaceFirst('${current.path}/', '');
        
        // 跳过特殊目录
        if (dirName == 'lib' || dirName == 'packages' || dirName == '.dart_tool') continue;
        
        // 检查是否已混淆
        if (_isAlreadyObfuscated(dirName)) continue;
        
        // 检查是否需要跳过
        if (_shouldSkipPath(relativePath)) {
          print('[DIR_SKIP] Kept prefix: $relativePath');
          continue;
        }
        
        // 创建目录信息
        // 如果是顶级目录（parentDir == null），传入 packagePrefix
        final dirInfo = _DirInfo(
          originName: dirName,
          parent: parentDir,
          packagePrefix: parentDir == null ? _packageName : null,
        );
        _allDirs.add(dirInfo);
        
        print('[DIR_COLLECT] $relativePath');
        
        // 递归处理子目录
        _collectAllInfo(entity, dirInfo);
        
      } else if (entity is File && entity.path.endsWith('.dart')) {
        final fileName = p.basename(entity.path);
        
        // 跳过已混淆的文件
        if (_isAlreadyObfuscated(fileName)) {
          print('[FILE_SKIP] Already obfuscated: $fileName');
          continue;
        }
        
        // 创建文件信息
        // 如果是顶级目录下的文件（parentDir == null），传入 packagePrefix
        final fileInfo = _FileInfo(
          name: fileName,
          parent: parentDir,
          packagePrefix: parentDir == null ? _packageName : null,
        );
        _allFiles.add(fileInfo);
        
        print('[FILE_COLLECT] ${fileInfo.outputFilePath()}');
      }
    }
  }

  // ============================================================
  // 第二步：收集所有文件的依赖关系
  // 
  // 遍历所有文件，检查它们的 import 语句，
  // 如果 import 指向了已收集的文件，则创建 DependInfo 并添加到引用方文件的列表
  // ============================================================
  void _collectAllDepends(Directory libDir) {
    print('[DEBUG] _allFiles contains ${_allFiles.length} files:');
    for (final fi in _allFiles) {
      print('  - ${fi.outputFilePath()}');
    }
    print('');
    var _list = libDir.listSync(recursive: true, followLinks: false);
    for (final file in _list) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      
      final currentFilePath = file.path.replaceFirst('${libDir.path}/', '');
      print('[DEBUG] Processing file: $currentFilePath');
      
      // 找到当前文件对应的 _FileInfo
      _FileInfo? currentFileInfo;
      for (final fi in _allFiles) {
        if (fi.rawFilePath() == currentFilePath) {
          currentFileInfo = fi;
          break;
        }
      }
      
      if (currentFileInfo == null) {
        print('[DEBUG]   Not found in _allFiles, skipping');
        continue;
      }
      
      print('[DEBUG]   Found in _allFiles: ${currentFileInfo.name}');
      
      try {
        final content = file.readAsStringSync();
        final lines = content.split('\n');
        
        int importCount = 0;
        int matchCount = 0;
        for (int i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          
          // 检查是否是 import、part 或 part of 语句
          if (!line.startsWith("import '") && !line.startsWith('import "') &&
              !line.startsWith("part '") && !line.startsWith('part "') &&
              !line.startsWith("part of '") && !line.startsWith('part of "')) continue;
          
          importCount++;
          
          // 提取路径
          String importPath;
          String prefix;
          
          // 判断语句类型并提取路径
          if (line.startsWith("import '")) {
            prefix = "import '";
          } else if (line.startsWith('import "')) {
            prefix = 'import "';
          } else if (line.startsWith("part '")) {
            prefix = "part '";
          } else if (line.startsWith('part "')) {
            prefix = 'part "';
          } else if (line.startsWith("part of '")) {
            prefix = "part of '";
          } else if (line.startsWith('part of "')) {
            prefix = 'part of "';
          } else {
            continue;
          }
          
          final startIdx = prefix.length;
          final endIdx = line.lastIndexOf("'");
          if (endIdx <= startIdx) continue;
          importPath = line.substring(startIdx, endIdx);
          
          print('[DEBUG]   Line ${i + 1}: $prefix$importPath"');
          
          // 检查路径指向了哪个已收集的文件
          bool hasMatch = false;
          for (final targetFile in _allFiles) {
            if (currentFileInfo == targetFile) continue;  // 跳过自己引用自己的情况
            
            if (_isTargetFile(importPath, targetFile)) {
              hasMatch = true;
              matchCount++;
              // 创建 DependInfo，添加到当前文件（引用方）的列表
              currentFileInfo.newUpdateImports.add(DependInfo(
                file: targetFile,  // 被引用方
                lineNum: i + 1,
                importPath: importPath,
                statementPrefix: prefix,
              ));
              
              print('[DEPEND] ${currentFileInfo.name} -> ${targetFile.name} line ${i + 1}: $importPath');
            }
          }
          
          if (!hasMatch) {
            print('[DEBUG]   No match for: $importPath');
          }
        }
        
        print('[DEBUG]   Total imports in file: $importCount');
        print('[DEBUG]   Total matches: $matchCount');
        print('[DEBUG]   ${currentFileInfo.name}.newUpdateImports.length = ${currentFileInfo.newUpdateImports.length}');
        
      } catch (e) {
        print('[ERROR] Failed to process ${file.path}: $e');
      }
      
      print('');
    }
    
    // 汇总日志
    print('[SUMMARY] After _collectAllDepends:');
    for (final fi in _allFiles) {
      print('  ${fi.name}: ${fi.newUpdateImports.length} dependencies');
    }
  }

  // ============================================================
  // 检查 import 路径是否引用了目标文件
  // ============================================================
  bool _isTargetFile(String importPath, _FileInfo targetFile) {
    final targetName = targetFile.name;
    
    // 检查是否是第三方包（package:xxx/ 但不是 package:$_packageName/）
    if (importPath.startsWith('package:') && !importPath.startsWith('package:$_packageName/')) {
      return false;
    }
    
    // 直接文件名匹配（同一目录下）
    if (importPath == targetName) {
      return true;
    }
    
    // 路径中包含目标文件名（带斜杠）
    if (importPath.contains('/$targetName')) {
      return true;
    }
    
    // 检查文件名是否是完整的（前后都有边界）
    // 文件名前必须是 /，后面必须是引号或字符串结束
    if (importPath.endsWith(targetName)) {
      // 检查后面是否是引号或字符串边界
      final afterEnd = importPath.length - targetName.length;
      if (afterEnd == 0 || afterEnd > 0) {
        final charAfter = afterEnd < importPath.length ? importPath[afterEnd] : '';
        if (charAfter == "'" || charAfter == '"' || charAfter == ' ') {
          return true;
        }
      }
    }
    
    return false;
  }

  // ============================================================
  // 第二步：执行所有重命名
  // ============================================================
  void _executeAllRenames(String projectRoot) {
    final libDir = Directory(p.join(projectRoot, 'lib'));
    
    // 目录重命名（按深度排序，深层先重命名）
    if (ENABLE_DIR_RENAMING) {
      print('[DIR_RENAME] Renaming directories...');
      _allDirs.sort((a, b) => b.depth.compareTo(a.depth));
      
      for (int i = 0; i < _allDirs.length; i++) {
        final dirInfo = _allDirs[i];
        final oldName = dirInfo.originName;
        final newName = _generateDirectoryName(oldName);
        
        print('[DIR ${i + 1}/${_allDirs.length}] $oldName -> $newName');
        
        // 使用 rawPath() 获取原始路径（不带 package 前缀）
        final oldPath = p.join(libDir.path, dirInfo.rawPath());
        final parentPath = p.dirname(oldPath);
        final newPath = p.join(parentPath, newName);
        
        if (!Directory(oldPath).existsSync()) {
          print('[DIR_SKIP] Not found: $oldPath');
          continue;
        }
        
        try {
          Directory(oldPath).renameSync(newPath);
          
          // 重命名成功后，更新 originName 为新名称
          dirInfo.originName = newName;
          
          print('[DIR_SUCCESS] Renamed');
        } catch (e) {
          print('[DIR_ERROR] Failed: $e');
        }
      }
      print('');
    }
    
    // 文件重命名
    if (ENABLE_FILE_RENAMING) {
      print('[FILE_RENAME] Renaming files...');
      
      for (int i = 0; i < _allFiles.length; i++) {
        final fileInfo = _allFiles[i];
        
        final oldName = fileInfo.name;
        final newName = _generateUniqueFileName(oldName);
        
        print('[FILE ${i + 1}/${_allFiles.length}] $oldName -> $newName');
        
        // 使用 rawFilePath() 获取原始路径（不带 package 前缀）
        final oldPath = p.join(libDir.path, fileInfo.rawFilePath());
        final parentPath = p.dirname(oldPath);
        final newPath = p.join(parentPath, newName);
        
        if (!File(oldPath).existsSync()) {
          print('[FILE_SKIP] Not found: $oldPath');
          continue;
        }
        
        try {
          File(oldPath).renameSync(newPath);
          
          // 重命名成功后，更新 name 为新名称
          fileInfo.name = newName;
          
          print('[FILE_SUCCESS] Renamed');
        } catch (e) {
          print('[FILE_ERROR] Failed: $e');
        }
      }
    }
  }

  // ============================================================
  // 第三步：更新所有依赖
  // 
  // 遍历所有文件 A：
  //   遍历 A.newUpdateImports（每个 DependInfo.file 指向被引用的文件 B）
  //     更新 A 中对应 DependInfo.lineNum 行的 import 语句
  // ============================================================
  void _updateAllDependencies(String projectRoot) {
    final libDir = Directory(p.join(projectRoot, 'lib'));
    int updatedFiles = 0;
    int updatedDepends = 0;
    
    print('[DEBUG] Starting _updateAllDependencies...');
    print('[DEBUG] _allFiles contains ${_allFiles.length} files');
    
    // 汇总每个文件的依赖数量
    for (final fi in _allFiles) {
      print('[DEBUG]   ${fi.name}: ${fi.newUpdateImports.length} dependencies');
    }
    print('');
    
    // 遍历所有文件
    for (final file in libDir.listSync(recursive: true, followLinks: false)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      
      final currentFilePath = file.path.replaceFirst('${libDir.path}/', '');
      
      // 找到当前文件对应的 _FileInfo
      _FileInfo? currentFileInfo;
      for (final fi in _allFiles) {
        if (fi.rawFilePath() == currentFilePath) {
          currentFileInfo = fi;
          break;
        }
      }
      if (currentFileInfo == null) {
        print('[DEBUG] File not in _allFiles: $currentFilePath, skipping');
        continue;
      }
      
      print('[DEBUG] Processing file: ${currentFileInfo.name}');
      print('[DEBUG]   newUpdateImports.length = ${currentFileInfo.newUpdateImports.length}');
      
      // 如果该文件没有需要更新的依赖，跳过
      if (currentFileInfo.newUpdateImports.isEmpty) {
        print('[DEBUG]   No dependencies to update, skipping');
        continue;
      }
      
      try {
        var content = file.readAsStringSync();
        final originalContent = content;
        final lines = content.split('\n');
        
        // 遍历该文件的所有依赖
        int fileUpdateCount = 0;
        for (final depend in currentFileInfo.newUpdateImports) {
          print('[DEBUG]   Depend: file=${depend.file.name}, line=${depend.lineNum}, importPath=${depend.importPath}');
          
          final lineNum = depend.lineNum - 1;
          if (lineNum < 0 || lineNum >= lines.length) {
            print('[DEBUG]     Invalid line number ${depend.lineNum}, skipping');
            continue;
          }
          
          final oldLine = lines[lineNum];
          final newFilePath = depend.file.outputFilePath();
          final oldImportPath = depend.importPath;
          print('[DEBUG]     Old line ${lineNum + 1}: $oldImportPath');
          print('[DEBUG]     New statement: $newFilePath');
          
          // 直接替换整行
          final newLine = oldLine.replaceFirst(oldImportPath, newFilePath);
          
          print('[DEBUG]     New line ${lineNum + 1}: $newLine');
          
          if (newLine != oldLine) {
            lines[lineNum] = newLine;
            fileUpdateCount++;
            updatedDepends++;
            print('[UPDATE] ${currentFileInfo.name} line ${depend.lineNum}: ${depend.importPath} -> ${depend.file.outputFilePath()}');
          } else {
            print('[DEBUG]     No change needed');
          }
        }
        
        print('[DEBUG]   Updated $fileUpdateCount imports in this file');
        
        if (content != lines.join('\n')) {
          content = lines.join('\n');
          file.writeAsStringSync(content);
          updatedFiles++;
          print('[DEBUG]   File written to disk');
        }
      } catch (e) {
        print('[ERROR] Failed to update ${file.path}: $e');
      }
      
      print('');
    }
    
    print('');
    print('[SUMMARY] Updated $updatedDepends dependencies in $updatedFiles files');
  }

  // ============================================================
  // 保存映射关系到文件
  // ============================================================
  void _saveMappingFile(String projectRoot) {
    final mappingFile = File(p.join(projectRoot, 'dart_obfuscator_file_mapping.txt'));
    final buffer = StringBuffer();
    
    buffer.writeln('=' * 60);
    buffer.writeln('DART OBFUSCATION MAPPING FILE');
    buffer.writeln('Generated at: ${DateTime.now()}');
    buffer.writeln('=' * 60);
    buffer.writeln();
    buffer.writeln('[CONFIG] ENABLE_FILE_RENAMING: $ENABLE_FILE_RENAMING');
    buffer.writeln('[CONFIG] ENABLE_DIR_RENAMING: $ENABLE_DIR_RENAMING');
    buffer.writeln();
    
    buffer.writeln('# DIRECTORY RENAMES:');
    buffer.writeln('-' * 60);
    for (final dir in _allDirs) {
      buffer.writeln(dir.outputPath());
    }
    buffer.writeln();
    
    buffer.writeln('# FILE RENAMES:');
    buffer.writeln('-' * 60);
    for (final file in _allFiles) {
      buffer.writeln(file.outputFilePath());
    }
    buffer.writeln();
    
    buffer.writeln('=' * 60);
    buffer.writeln('END OF MAPPING');
    buffer.writeln('=' * 60);
    
    mappingFile.writeAsStringSync(buffer.toString());
    print('[INFO] Mapping saved to: ${mappingFile.path}');
  }
}

// ============================================================
// 数据结构定义
// ============================================================

// 目录信息
class _DirInfo {
  String originName;           // 当前目录名（可更新）
  final _DirInfo? parent;     // 父目录指针
  final String? packagePrefix; // package 前缀（如 'live'），只有顶级目录才有值
  
  _DirInfo({
    required this.originName,
    required this.parent,
    this.packagePrefix,
  });
  
  // 计算目录深度
  int get depth {
    int count = 0;
    _DirInfo? current = parent;
    while (current != null) {
      count++;
      current = current.parent;
    }
    return count;
  }
  
  // 输出当前目录路径（带 package 前缀，用于 import）
  String outputPath() {
    final path = parent == null ? originName : '${parent!.outputPath()}/$originName';
    
    // 只有顶级目录（parent == null）才添加 package 前缀
    if (parent == null && packagePrefix != null) {
      return 'package:$packagePrefix/$path';
    }
    return path;
  }
  
  // 输出原始目录路径（不带 package 前缀，用于文件系统操作）
  String rawPath() {
    if (parent == null) {
      return originName;
    }
    return '${parent!.rawPath()}/$originName';
  }
}

// 依赖信息
class DependInfo {
  final _FileInfo file;           // 依赖指向的文件
  final int lineNum;            // 第几行依赖
  final String importPath;       // 原始路径（如 app/routes/app_routes.dart）
  final String statementPrefix;   // 语句前缀（import '、part '、part of ' 等）
  
  DependInfo({
    required this.file,
    required this.lineNum,
    required this.importPath,
    required this.statementPrefix,
  });
  
  // 计算新的完整语句
  // 例如：import 'app/routes/app_routes.dart' -> import 'package:live/app/routes/triceratops1.dart'
  String newStatement() {
    return "$statementPrefix${file.outputFilePath()}';";
  }
}

// 文件信息
class _FileInfo {
  String name;              // 当前文件名（可更新）
  final _DirInfo? parent;         // 父目录指针
  final String? packagePrefix;     // package 前缀（如 'live'），只有顶级目录的文件才有值
  final List<DependInfo> newUpdateImports;  // 需要被更新的依赖信息
  
  _FileInfo({
    required this.name,
    required this.parent,
    this.packagePrefix,
  }) : newUpdateImports = [];
  
  // 输出当前文件路径（带 package 前缀，用于 import）
  String outputFilePath() {
    final fileName = name;
    
    // 如果是顶级目录（parent == null），添加 package 前缀
    if (parent == null && packagePrefix != null) {
      return 'package:$packagePrefix/$fileName';
    }
    
    // 否则使用父目录的路径
    if (parent == null) {
      return fileName;
    }
    return '${parent!.outputPath()}/$fileName';
  }
  
  // 输出原始文件路径（不带 package 前缀，用于文件系统操作）
  String rawFilePath() {
    if (parent == null) {
      return name;
    }
    return '${parent!.rawPath()}/$name';
  }
}
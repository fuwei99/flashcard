/// 学习会话断点存储
/// ================================================================
/// workflow.js 每一步调 `session.save` 落在这里；杀后台重进能续上。
/// 落盘：<公共目录>/Flashcard/session.json（Agent 可读，可手动清）。
///
/// 只存「一个」当前会话（单会话模型）—— 背单词是线性流程，不存在并发会话。
library;

import 'dart:io';

import 'data_dir.dart';

class SessionStore {
  static const _fileName = 'session.json';

  Map<String, dynamic> _data = {};

  /// 上次未完成的会话：{ workflow, cursor, updated_at }
  Map<String, dynamic> get data => Map.unmodifiable(_data);

  bool get hasSession => _data.isNotEmpty;

  /// 从公共目录读一次（公共目录不可用则内存空转）
  void init() {
    final doc = DataDir.readJsonSync(_fileName);
    if (doc != null) _data = doc;
  }

  void save(String workflow, dynamic cursor) {
    _data = {
      'workflow': workflow,
      'cursor': cursor,
      'updated_at': DateTime.now().toIso8601String(),
    };
    DataDir.writeJsonSync(_fileName, _data);
  }

  void clear() {
    _data = {};
    final root = DataDir.cachedRoot;
    if (root == null) return;
    try {
      final f = File('${root.path}/$_fileName');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

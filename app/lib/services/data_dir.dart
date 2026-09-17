/// 数据落地目录
/// ================================================================
/// 所有数据都放在手机**公共文件夹**，Agent / 文件管理器可直接读写：
///
///   /storage/emulated/0/Documents/Flashcard/
///     ├── settings.json          学习设置 / 每日进度 / 打卡 / 统计 / 提醒
///     ├── progress.json          每张卡的调度状态(FSRS) + 卡片私有 KV
///     ├── books/<book_id>.json   导入的书（书 + 该书进度）
///     └── export/<book_id>.json  手动「导出」出来的书
///
/// 目录不可写（没给「所有文件访问权限」）时自动退回 app 私有目录，
/// app 仍能用，但 Agent 读不到 —— 这时需要在系统设置里授权。
library;

import 'dart:convert';
import 'dart:io';

class DataDir {
  /// 公共根目录（Android 上 = 内部存储/Documents/Flashcard）
  static const publicPath = '/storage/emulated/0/Documents/Flashcard';

  /// 老版本导出目录（小写），首次启动把里面的文件搬到 export/
  static const _legacyPath = '/storage/emulated/0/Documents/flashcard';

  static Directory? _root;
  static bool _resolved = false;

  /// 丢弃已缓存的解析结果，下次 [root()] 重新探测一次。
  ///
  /// 必须留这个口子：首次安装时 App 还没拿到「所有文件访问权限」，
  /// [root()] 必然失败，而失败结果会被缓存 —— 用户在弹窗里点了授权之后
  /// 如果没人来清缓存，就只能杀进程重启才生效。
  static void invalidate() {
    _resolved = false;
    _root = null;
  }

  /// 重新探测一次（授权回调里用）；返回这次是否可用
  static Future<Directory?> recheck() async {
    invalidate();
    return root();
  }

  /// 解析并缓存根目录；不可用返回 null（只解析一次）
  static Future<Directory?> root() async {
    if (_resolved) return _root;
    try {
      final d = Directory(publicPath);
      if (!await d.exists()) await d.create(recursive: true);
      // 只 create 不代表能写，真写一次探针确认权限
      final probe = File('${d.path}/.write_test');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      _root = d;
      _resolved = true;
      await _migrateLegacy(d);
    } catch (_) {
      // 探测失败**不**置 _resolved —— 权限随时可能被授予，下次再试。
      // 以前这个值在 try 之前就置 true，导致首次安装的失败被永久缓存。
      _root = null;
    }
    return _root;
  }

  /// 同步取根目录 —— 必须先 await root() 解析过
  static Directory? get cachedRoot => _root;

  /// 公共目录是否可用（UI 上据此提示去授权）
  static bool get available => _root != null;

  static Future<void> _migrateLegacy(Directory to) async {
    try {
      final old = Directory(_legacyPath);
      if (!await old.exists()) return;
      final exportDir = Directory('${to.path}/export');
      await for (final e in old.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final name = e.uri.pathSegments.last;
        final dest = File('${exportDir.path}/$name');
        if (await dest.exists()) continue;
        if (!await exportDir.exists()) await exportDir.create(recursive: true);
        await e.copy(dest.path);
      }
    } catch (_) {}
  }

  /// 子目录（默认创建）
  static Future<Directory?> sub(String name, {bool create = true}) async {
    final r = await root();
    if (r == null) return null;
    final d = Directory('${r.path}/$name');
    if (create && !await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 读 JSON；文件不存在 / 解析失败返回 null
  static Map<String, dynamic>? readJsonSync(String name) {
    final r = _root;
    if (r == null) return null;
    try {
      final f = File('${r.path}/$name');
      if (!f.existsSync()) return null;
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return null;
      final m = json.decode(raw);
      return m is Map ? Map<String, dynamic>.from(m) : null;
    } catch (_) {
      return null;
    }
  }

  /// 同步写 JSON（先写 .tmp 再 rename，避免写一半被读到）
  static bool writeJsonSync(String name, Object data) {
    final r = _root;
    if (r == null) return false;
    try {
      final f = File('${r.path}/$name');
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
      tmp.renameSync(f.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> readJson(String name) async {
    await root();
    return readJsonSync(name);
  }

  static Future<bool> writeJson(String name, Object data) async {
    await root();
    return writeJsonSync(name, data);
  }
}

/// 模板文件接口（fs.*）
/// ================================================================
/// 给模板 script.js / workflow.js 的通用文件读写能力，走双向 RPC。
///
/// 边界：所有路径都相对 [DataDir.root()]（= Documents/Flashcard/），
/// 规范化（吃掉 `.` / `..`）后必须落在 [allowedPrefixes] 白名单里，
/// 否则直接拒绝。默认只开 `books/`。
///
/// 方法一览：
///   fs.info                        根目录 / 白名单 / 上限
///   fs.list   {path}               列目录
///   fs.read   {path}               读文本
///   fs.write  {path, content}      写文本（.tmp + rename 原子写）
///   fs.append {path, content}      追加
///   fs.delete {path, recursive}    删文件 / 目录
///   fs.move   {from, to, overwrite}
///   fs.copy   {from, to, overwrite}
///   fs.mkdir  {path}
///   fs.stat   {path}
///   fs.exists {path | paths}
///
/// 失败一律 throw —— [BridgeRpc.dispatch] 会兜住并回 `ok:false` + error。
library;

import 'dart:convert';
import 'dart:io';

import 'bridge_rpc.dart';
import 'data_dir.dart';

class TemplateFs {
  /// 允许读写的路径前缀（相对数据根）。空列表 = 整个根放行。
  final List<String> allowedPrefixes;

  /// 单文件读写上限（字节）。防呆，不是安全边界。
  final int maxBytes;

  TemplateFs({
    this.allowedPrefixes = const ['books'],
    this.maxBytes = 8 * 1024 * 1024,
  });

  /// 把 fs.* 全部挂到 RPC 表上
  void registerInto(BridgeRpc rpc) {
    rpc.register('fs.info', (p) async => _info());
    rpc.register('fs.list', (p) async => _list(p));
    rpc.register('fs.read', (p) async => _read(p));
    rpc.register('fs.write', (p) async => _write(p));
    rpc.register('fs.append', (p) async => _append(p));
    rpc.register('fs.delete', (p) async => _delete(p));
    rpc.register('fs.move', (p) async => _move(p));
    rpc.register('fs.copy', (p) async => _copy(p));
    rpc.register('fs.mkdir', (p) async => _mkdir(p));
    rpc.register('fs.stat', (p) async => _stat(p));
    rpc.register('fs.exists', (p) async => _exists(p));
  }

  // ---------------------------------------------------------------
  // 方法
  // ---------------------------------------------------------------

  Future<Map<String, dynamic>> _info() async {
    final root = await DataDir.root();
    return {
      'ok': true,
      'available': root != null,
      'root': DataDir.publicPath,
      'allowed': allowedPrefixes,
      'maxBytes': maxBytes,
    };
  }

  Future<Map<String, dynamic>> _list(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final root = await _rootOrThrow();
    final dir = Directory('${root.path}/$rel');
    if (!await dir.exists()) throw '目录不存在: $rel';
    final out = <Map<String, dynamic>>[];
    await for (final e in dir.list(followLinks: false)) {
      final name = e.path.split('/').last;
      final st = await e.stat();
      out.add({
        'name': name,
        'path': '$rel/$name',
        'dir': e is Directory,
        'size': st.size,
        'mtime': st.modified.toIso8601String(),
      });
    }
    out.sort((a, b) {
      final da = a['dir'] == true ? 0 : 1;
      final db = b['dir'] == true ? 0 : 1;
      if (da != db) return da - db;
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return {'ok': true, 'path': rel, 'count': out.length, 'entries': out};
  }

  Future<Map<String, dynamic>> _read(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final root = await _rootOrThrow();
    final f = File('${root.path}/$rel');
    if (!await f.exists()) throw '文件不存在: $rel';
    final size = await f.length();
    if (size > maxBytes) throw '文件过大 ($size > $maxBytes): $rel';
    return {
      'ok': true,
      'path': rel,
      'size': size,
      'content': await f.readAsString(),
    };
  }

  Future<Map<String, dynamic>> _write(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final content = (p['content'] ?? '').toString();
    final n = utf8.encode(content).length;
    if (n > maxBytes) throw '内容过大 ($n > $maxBytes): $rel';
    final root = await _rootOrThrow();
    final f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
    final st = await f.stat();
    return {
      'ok': true,
      'path': rel,
      'size': st.size,
      'mtime': st.modified.toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _append(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final content = (p['content'] ?? '').toString();
    final root = await _rootOrThrow();
    final f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(content, mode: FileMode.append, flush: true);
    final st = await f.stat();
    return {'ok': true, 'path': rel, 'size': st.size};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final root = await _rootOrThrow();
    final abs = '${root.path}/$rel';
    final f = File(abs);
    if (await f.exists()) {
      await f.delete();
      return {'ok': true, 'path': rel, 'type': 'file'};
    }
    final d = Directory(abs);
    if (await d.exists()) {
      final rec = p['recursive'] == true;
      await d.delete(recursive: rec);
      return {'ok': true, 'path': rel, 'type': 'dir', 'recursive': rec};
    }
    throw '不存在: $rel';
  }

  Future<Map<String, dynamic>> _move(Map<String, dynamic> p) async {
    final from = _clean((p['from'] ?? '').toString());
    final to = _clean((p['to'] ?? '').toString());
    final root = await _rootOrThrow();
    final src = await _entity(root.path, from);
    final dstAbs = '${root.path}/$to';
    await _prepDst(dstAbs, p['overwrite'] == true, to);
    try {
      await src.rename(dstAbs);
    } catch (_) {
      // 跨设备 rename 会失败，退化成 copy + delete
      if (src is File) {
        await src.copy(dstAbs);
        await src.delete();
      } else if (src is Directory) {
        await _copyDir(src, Directory(dstAbs));
        await src.delete(recursive: true);
      }
    }
    return {'ok': true, 'from': from, 'to': to};
  }

  Future<Map<String, dynamic>> _copy(Map<String, dynamic> p) async {
    final from = _clean((p['from'] ?? '').toString());
    final to = _clean((p['to'] ?? '').toString());
    final root = await _rootOrThrow();
    final src = await _entity(root.path, from);
    final dstAbs = '${root.path}/$to';
    await _prepDst(dstAbs, p['overwrite'] == true, to);
    if (src is File) {
      await src.copy(dstAbs);
    } else if (src is Directory) {
      await _copyDir(src, Directory(dstAbs));
    }
    return {'ok': true, 'from': from, 'to': to};
  }

  Future<Map<String, dynamic>> _mkdir(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final root = await _rootOrThrow();
    await Directory('${root.path}/$rel').create(recursive: true);
    return {'ok': true, 'path': rel};
  }

  Future<Map<String, dynamic>> _stat(Map<String, dynamic> p) async {
    final rel = _clean((p['path'] ?? '').toString());
    final root = await _rootOrThrow();
    final e = await _entity(root.path, rel);
    final st = await e.stat();
    return {
      'ok': true,
      'path': rel,
      'dir': e is Directory,
      'size': st.size,
      'mtime': st.modified.toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _exists(Map<String, dynamic> p) async {
    final raw = p['paths'];
    final list = raw is List
        ? raw.map((e) => e.toString()).toList()
        : <String>[(p['path'] ?? '').toString()];
    final root = await DataDir.root();
    if (root == null) return {'ok': true, 'available': false, 'result': {}};
    final out = <String, bool>{};
    for (final r0 in list) {
      try {
        final rel = _clean(r0);
        out[r0] = await File('${root.path}/$rel').exists() ||
            await Directory('${root.path}/$rel').exists();
      } catch (_) {
        out[r0] = false;
      }
    }
    return {'ok': true, 'available': true, 'result': out};
  }

  // ---------------------------------------------------------------
  // 路径解析 / 守卫
  // ---------------------------------------------------------------

  /// 规范化 + 白名单校验，返回相对根的干净路径
  String _clean(String raw) {
    final s = raw.trim().replaceAll('\\', '/');
    final parts = <String>[];
    for (final seg in s.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) throw '路径越界: $raw';
        parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    if (parts.isEmpty) throw '空路径';
    final rel = parts.join('/');
    _guard(rel, raw);
    return rel;
  }

  void _guard(String rel, String raw) {
    if (allowedPrefixes.isEmpty) return;
    for (final p in allowedPrefixes) {
      if (rel == p || rel.startsWith('$p/')) return;
    }
    throw '路径不在允许范围 (${allowedPrefixes.join(", ")}): $raw';
  }

  Future<Directory> _rootOrThrow() async {
    final r = await DataDir.root();
    if (r == null) {
      throw '数据目录不可用：请在系统设置里给 App「所有文件访问」权限';
    }
    return r;
  }

  Future<FileSystemEntity> _entity(String rootPath, String rel) async {
    final abs = '$rootPath/$rel';
    final f = File(abs);
    if (await f.exists()) return f;
    final d = Directory(abs);
    if (await d.exists()) return d;
    throw '不存在: $rel';
  }

  /// 目标已存在时按 overwrite 决定覆盖还是报错；并建好父目录
  Future<void> _prepDst(String dstAbs, bool overwrite, String to) async {
    final f = File(dstAbs);
    final d = Directory(dstAbs);
    if (await f.exists() || await d.exists()) {
      if (!overwrite) throw '目标已存在: $to';
      if (await f.exists()) {
        await f.delete();
      } else {
        await d.delete(recursive: true);
      }
    }
    await Directory(f.parent.path).create(recursive: true);
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = e.path.split('/').last;
      final target = '${dst.path}/$name';
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }
}

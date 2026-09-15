/// 书本 / 模板 仓库层
/// ================================================================
/// **模板**（HTML/CSS/JS/manifest）优先从公共目录读：
///   <Documents>/Flashcard/templates/<template_id>/
///     ├── manifest.json
///     ├── template.html
///     ├── style.css
///     └── script.js
/// 首次运行会把内置模板铺一份过去（已存在的不覆盖）。
/// 之后想怎么美化 CSS / 改 HTML / 改 JS，直接改文件 → 「我的」页点
/// 「重载模板」即可生效，不用重新编译 APK。
///
/// **书本**来源三处，按 bookId 去重：
///   1. 内置 asset（assets/decks/*.json，只读）
///   2. <Documents>/Flashcard/books/*.json（Agent 可直接丢书进来）
///   3. app 私有目录 <appdoc>/books/*.json（老数据，兼容读）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'data_dir.dart';

class DeckRepository {
  static const _assetBooks = <String>[
    'assets/decks/kaoyan_core.json',
  ];

  static const _templateDirs = <String>[
    'assets/templates/bubei_dark',
    'assets/templates/mixup_dark',
  ];

  /// 一个模板包固定这几个文件
  static const _templateFiles = <String>[
    'manifest.json',
    'template.html',
    'style.css',
    'script.js',
  ];

  /// 公共目录里的模板根目录
  static String get templatesPath => '${DataDir.publicPath}/templates';

  // ===============================================================
  // 模板
  // ===============================================================

  /// 首次运行：把内置模板复制到公共目录（已存在的不覆盖）
  /// 返回复制了多少个文件；公共目录不可用返回 -1
  Future<int> seedPublicTemplates() async {
    final root = await DataDir.sub('templates');
    if (root == null) return -1;
    var copied = 0;
    for (final assetDir in _templateDirs) {
      final id = assetDir.split('/').last;
      final target = Directory('${root.path}/$id');
      for (final name in _templateFiles) {
        try {
          final f = File('${target.path}/$name');
          if (await f.exists()) continue; // 用户改过的不动
          final content = await rootBundle.loadString('$assetDir/$name');
          if (!await target.exists()) await target.create(recursive: true);
          await f.writeAsString(content);
          copied++;
        } catch (_) {}
      }
    }
    return copied;
  }

  /// 从一个目录读模板包（文件名以 manifest 里的 files 为准）
  Future<CardTemplate?> _loadTemplateFromDir(Directory dir) async {
    try {
      final mf = File('${dir.path}/manifest.json');
      if (!await mf.exists()) return null;
      final manifest =
          json.decode(await mf.readAsString()) as Map<String, dynamic>;
      final files = manifest['files'] is Map
          ? Map<String, dynamic>.from(manifest['files'] as Map)
          : const <String, dynamic>{};

      Future<String> read(String key, String fallback) async {
        final name = (files[key] ?? fallback).toString();
        final f = File('${dir.path}/$name');
        if (!await f.exists()) return '';
        return await f.readAsString();
      }

      return CardTemplate(
        manifest: manifest,
        html: await read('template', 'template.html'),
        css: await read('style', 'style.css'),
        js: await read('script', 'script.js'),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读一个内置模板包（asset）
  Future<CardTemplate> loadTemplateAsset(String dir) async {
    final manifest = json.decode(
      await rootBundle.loadString('$dir/manifest.json'),
    ) as Map<String, dynamic>;

    Future<String> maybe(String name) async {
      try {
        return await rootBundle.loadString('$dir/$name');
      } catch (_) {
        return '';
      }
    }

    return CardTemplate(
      manifest: manifest,
      html: await maybe('template.html'),
      css: await maybe('style.css'),
      js: await maybe('script.js'),
    );
  }

  /// 所有可用模板：公共目录优先，内置补缺
  Future<Map<String, CardTemplate>> loadAllTemplates() async {
    final out = <String, CardTemplate>{};

    // 1) 公共目录（可随时改，改了重载即可）
    final pub = await DataDir.sub('templates', create: false);
    if (pub != null) {
      try {
        if (await pub.exists()) {
          final ents = await pub.list().toList()
            ..sort((a, b) => a.path.compareTo(b.path));
          for (final e in ents) {
            if (e is! Directory) continue;
            final t = await _loadTemplateFromDir(e);
            if (t != null) out[t.id] = t;
          }
        }
      } catch (_) {}
    }

    // 2) 内置模板补缺（公共目录里删掉了某个模板还能兜住）
    for (final d in _templateDirs) {
      try {
        final t = await loadTemplateAsset(d);
        out.putIfAbsent(t.id, () => t);
      } catch (_) {}
    }

    return out;
  }

  // ===============================================================
  // 书本
  // ===============================================================

  /// 读一本书（asset）
  Future<Book> loadBookAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return Book.fromJson(json.decode(raw) as Map<String, dynamic>);
  }

  /// 用户导入 / 手动放入的书所在目录（公共目录优先）
  Future<List<Directory>> _booksDirs() async {
    final dirs = <Directory>[];
    final pub = await DataDir.sub('books', create: false);
    if (pub != null) dirs.add(pub);
    try {
      final base = await getApplicationDocumentsDirectory();
      dirs.add(Directory('${base.path}/books'));
    } catch (_) {}
    return dirs;
  }

  /// 用户导入的书
  Future<List<Book>> loadImportedBooks() async {
    final out = <Book>[];
    final seen = <String>{};
    for (final dir in await _booksDirs()) {
      try {
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          if (e is! File || !e.path.endsWith('.json')) continue;
          try {
            final raw = await e.readAsString();
            final b = Book.fromJson(json.decode(raw) as Map<String, dynamic>);
            if (seen.add(b.bookId)) out.add(b);
          } catch (_) {}
        }
      } catch (_) {}
    }
    return out;
  }

  /// 书架上的所有书 = 内置 + 导入
  Future<List<Book>> loadAllBooks() async {
    final out = <Book>[];
    for (final p in _assetBooks) {
      try {
        out.add(await loadBookAsset(p));
      } catch (_) {}
    }
    out.addAll(await loadImportedBooks());
    return out;
  }
}

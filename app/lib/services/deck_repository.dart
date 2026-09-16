/// 书本 / 模板 仓库层
/// ================================================================
/// **模板**（HTML/CSS/JS/manifest）优先从公共目录读：
///   <Documents>/Flashcard/templates/<template_id>/
/// 首次运行会把内置模板铺一份过去（已存在的不覆盖）。
/// 之后想怎么美化 CSS / 改 HTML / 改 JS，直接改文件 → 「我的」页点
/// 「重载模板」即可生效，不用重新编译 APK。
///
/// **书本**有两种落盘格式：
///   1. 分片（新，v0.7.0）：
///        books/<book_id>/index.json     书元信息 + 章节目录（标题/卡片数/卡片 id/语篇）
///        books/<book_id>/ch_0001.json   第 1 章，只有卡片
///      —— 启动只读 index.json，首页算「今天到期/新词」一张卡都不用载入；
///         真开背才按章读盘；Agent 改第 3 章就只动 ch_0003.json。
///   2. 单文件（旧）：books/<book_id>.json
///      —— 读到之后自动拆成分片目录，原文件改名 .json.bak 留底。
///
/// 来源目录：
///   1. <Documents>/Flashcard/books/   （公共目录，Agent 可直接丢书）
///   2. <appdoc>/books/                （老数据，兼容读）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
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
    'workflow.js',
  ];

  /// 公共目录里的模板根目录
  static String get templatesPath => '${DataDir.publicPath}/templates';

  /// 公共目录里的书本根目录
  static String get booksPath => '${DataDir.publicPath}/books';

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
      // 目录已存在且非空 → 这是用户自己的模板，整个跳过：不覆盖、也不补缺文件
      if (await target.exists() && !(await target.list().isEmpty)) continue;
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

  // ===============================================================
  // 说明文档（给 Agent / 用户看）
  // ===============================================================

  /// 内置说明文档在 assets 里的目录（真源在仓库 text/readme/，CI 同步过来）
  static const _readmeAssetDir = 'assets/readme';

  /// 文档自带的版本号：头部 front-matter 里的 `doc_version: N`
  static int _docVersionOf(String text) {
    final m = RegExp(r'^doc_version:\s*(\d+)', multiLine: true).firstMatch(text);
    if (m == null) return 0;
    return int.tryParse(m.group(1)!) ?? 0;
  }

  /// 列出 assets/readme/ 下所有 .md。
  /// 走 AssetManifest 动态枚举 —— **新增文档不用改任何代码**。
  Future<List<String>> _readmeAssets() async {
    try {
      final m = await AssetManifest.loadFromAssetBundle(rootBundle);
      final keys = m
          .listAssets()
          .where((k) => k.startsWith('$_readmeAssetDir/') && k.endsWith('.md'))
          .toList()
        ..sort();
      if (keys.isNotEmpty) return keys;
    } catch (_) {}
    return const ['$_readmeAssetDir/如何管理单词.md'];
  }

  /// 把内置说明文档铺到公共目录（直接铺在 Flashcard/ 下），让 Agent 能直接读。
  ///
  /// **版本感知**：文档头部有 `doc_version: N`
  ///   - 公共目录没有            → 写入
  ///   - 公共目录版本更旧        → 覆盖（schema 更新能推下去）
  ///   - 公共目录版本相同或更新  → 不动（用户自己改过、批注过的保留）
  ///
  /// 返回写入的文件数；公共目录不可用返回 -1。
  Future<int> seedReadme() async {
    final root = await DataDir.root();
    if (root == null) return -1;
    var written = 0;
    for (final asset in await _readmeAssets()) {
      final name = asset.split('/').last;
      if (name.isEmpty) continue;
      try {
        final bundled = await rootBundle.loadString(asset);
        final f = File('${root.path}/$name');
        if (await f.exists()) {
          final local = await f.readAsString();
          if (_docVersionOf(local) >= _docVersionOf(bundled)) continue;
        }
        await f.writeAsString(bundled);
        written++;
      } catch (_) {}
    }
    return written;
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
        workflow: await read('workflow', 'workflow.js'),
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
      workflow: await maybe('workflow.js'),
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

  /// 读一本书（内置 asset，老格式）
  Future<Book> loadBookAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return Book.fromJson(json.decode(raw) as Map<String, dynamic>);
  }

  /// 用户书的来源目录（公共目录优先）
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

  /// 公共/私有 books 目录（写入用；优先公共）
  Future<Directory> writableBooksDir() async {
    final pub = await DataDir.sub('books');
    if (pub != null) return pub;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/books');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 用户导入 / 手动放入的书
  Future<List<Book>> loadImportedBooks() async {
    final out = <Book>[];
    final seen = <String>{};
    for (final dir in await _booksDirs()) {
      try {
        if (!await dir.exists()) continue;
        // 先把目录项收完再处理：_shardLegacy 会在遍历中建目录 / 改名，
        // 边遍历边改目录会让 stream 漏项。
        final entries = await dir.list().toList();
        for (final e in entries) {
          try {
            if (e is Directory) {
              // 分片格式
              final idx = File('${e.path}/index.json');
              if (!await idx.exists()) continue;
              final raw = await idx.readAsString();
              final b = Book.fromIndex(
                  json.decode(raw) as Map<String, dynamic>, e.path);
              if (seen.add(b.bookId)) out.add(b);
            } else if (e is File && e.path.endsWith('.json')) {
              // 老的单文件格式 → 读 + 自动拆片
              final raw = await e.readAsString();
              final b = Book.fromJson(json.decode(raw) as Map<String, dynamic>);
              if (!seen.add(b.bookId)) continue;
              out.add(b);
              await _shardLegacy(b, dir.path, e);
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return out;
  }

  /// 把老的「单文件带章节」书拆成分片目录，原文件改名 .json.bak 留底。
  /// 没有章节的书保持单文件（通常很小，不值得拆）。
  Future<bool> _shardLegacy(Book b, String parent, File from) async {
    if (!b.hasChapters) return false;
    final dir = Directory('$parent/${b.bookId}');
    try {
      if (await dir.exists()) return false;
      await dir.create(recursive: true);

      var i = 0;
      for (final c in b.chapters) {
        i++;
        final name = 'ch_${i.toString().padLeft(4, '0')}.json';
        await File('${dir.path}/$name').writeAsString(
          const JsonEncoder.withIndent('  ').convert(c.toJson()),
        );
      }

      await File('${dir.path}/index.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(b.toIndexJson()),
      );

      try {
        await from.rename('${from.path}.bak');
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把一本书写成分片目录（有章节）/ 单文件（无章节）
  Future<void> saveImportedBook(Book book) async {
    final booksDir = await writableBooksDir();

    if (!book.hasChapters) {
      final file = File('${booksDir.path}/${book.bookId}.json');
      await file.writeAsString(json.encode(book.toJson()));
      // 这本书之前可能是分片目录 / .bak 备份，单文件写完后要清干净，
      // 否则下次读盘先撞上旧目录里的 index.json，读到过期内容。
      final oldDir = Directory('${booksDir.path}/${book.bookId}');
      if (await oldDir.exists()) await oldDir.delete(recursive: true);
      final oldBak = File('${booksDir.path}/${book.bookId}.json.bak');
      if (await oldBak.exists()) await oldBak.delete();
      return;
    }

    final dir = Directory('${booksDir.path}/${book.bookId}');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    var i = 0;
    for (final c in book.chapters) {
      i++;
      final name = 'ch_${i.toString().padLeft(4, '0')}.json';
      await File('${dir.path}/$name').writeAsString(
        const JsonEncoder.withIndent('  ').convert(c.toJson()),
      );
    }

    await File('${dir.path}/index.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(book.toIndexJson()),
    );

    // 顺手清掉可能存在的同名单文件
    final old = File('${booksDir.path}/${book.bookId}.json');
    if (await old.exists()) await old.delete();
  }

  /// 删除一本导入的书（分片目录 / 单文件都删）
  Future<void> deleteImportedBook(String bookId) async {
    final booksDir = await writableBooksDir();
    final dir = Directory('${booksDir.path}/$bookId');
    if (await dir.exists()) await dir.delete(recursive: true);
    for (final suffix in ['', '.bak']) {
      final f = File('${booksDir.path}/$bookId.json$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  /// 公共 books 目录里是否已有内容
  Future<bool> _hasPublicBooks() async {
    final pub = await DataDir.sub('books', create: false);
    if (pub == null) return false;
    try {
      if (!await pub.exists()) return false;
      return !(await pub.list().isEmpty);
    } catch (_) {
      return false;
    }
  }

  /// 书架上的所有书 = 内置 + 导入。
  /// 公共 books 目录里只要已经有内容，就认为书是用户自己在管，不再导入内置词书。
  Future<List<Book>> loadAllBooks() async {
    final out = <Book>[];
    if (!await _hasPublicBooks()) {
      for (final p in _assetBooks) {
        try {
          out.add(await loadBookAsset(p));
        } catch (_) {}
      }
    }
    out.addAll(await loadImportedBooks());
    return out;
  }
}
